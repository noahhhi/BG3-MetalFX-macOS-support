// bg3-metalfx：Steam 启动选项用的 Mach-O 包装器。
// Steam 对 shell 脚本形式的启动选项在本机报 "OS Error 0"（进程都未创建），
// 因此用真正的可执行文件作为 %command% 前缀。
//
// 行为与 scripts/launch.zsh 等价：
// 1. 拼接被 Steam 拆分的路径 token，直到找到存在的目标；
// 2. 兼容传入 .app 目录或主程序；
// 3. realpath 校验目标必须是本机这份 BG3 主程序，否则拒绝（exit 64）；
// 4. 把本项目的 dylib 前置到 DYLD_INSERT_LIBRARIES（保留 Steam 自有注入）；
// 5. execv 目标，透传其余参数。
// 日志只写 runs/launch.log，一行事件，不记录参数全文。

#include <errno.h>
#include <limits.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// 安装根目录：BG3MF_HOME 优先，默认 ~/Library/Application Support/BG3MetalFX。
static void bg3mf_home(char *out, size_t n) {
    const char *h = getenv("BG3MF_HOME");
    if (h && h[0]) {
        snprintf(out, n, "%s", h);
        return;
    }
    const char *home = getenv("HOME");
    snprintf(out, n, "%s/Library/Application Support/BG3MetalFX",
             home ? home : ".");
}

static void log_event(const char *msg) {
    char home[PATH_MAX], path[PATH_MAX * 2];
    bg3mf_home(home, sizeof(home));
    snprintf(path, sizeof(path), "%s/runs/launch.log", home);
    FILE *f = fopen(path, "a");
    if (!f) return;
    fprintf(f, "BG3MF_LAUNCH ts=%ld %s pid=%d\n", (long)time(NULL), msg,
            (int)getpid());
    fclose(f);
}

static int fail(const char *reason) {
    log_event(reason);
    fprintf(stderr, "bg3mf_launcher: refuse: %s\n", reason);
    return 64;
}

int main(int argc, char *argv[]) {
    if (argc < 2) return fail("no target from steam");

    // dylib 与包装器自身同目录（pkg 安装与开发 build 目录均满足）。
    char self[PATH_MAX], dylib[PATH_MAX * 2], selfdir[PATH_MAX];
    if (!realpath(argv[0], self)) return fail("realpath self failed");
    snprintf(selfdir, sizeof(selfdir), "%s", self);
    char *slash = strrchr(selfdir, '/');
    if (slash) *slash = '\0';
    snprintf(dylib, sizeof(dylib), "%s/libbg3mf_probe.dylib", selfdir);

    struct stat st;
    if (stat(dylib, &st) != 0) return fail("dylib missing");

    // 1. 拼接目标路径
    char target[PATH_MAX * 2];
    target[0] = '\0';
    int consumed = 0;
    for (int i = 1; i < argc; i++) {
        if (target[0] != '\0') strlcat(target, " ", sizeof(target));
        strlcat(target, argv[i], sizeof(target));
        consumed = i;
        if (stat(target, &st) == 0) break;
    }
    if (stat(target, &st) != 0) return fail("target not found");

    // 2. .app 目录 → 主程序
    char candidate[PATH_MAX * 2];
    if (S_ISDIR(st.st_mode)) {
        snprintf(candidate, sizeof(candidate),
                 "%s/Contents/MacOS/Baldur's Gate 3", target);
    } else {
        snprintf(candidate, sizeof(candidate), "%s", target);
    }
    if (stat(candidate, &st) != 0 || !(st.st_mode & S_IXUSR)) {
        return fail("target not executable");
    }

    // 3. realpath 校验：必须落在 BG3 主程序路径上（不限定 Steam 库位置）
    char real_cand[PATH_MAX];
    if (!realpath(candidate, real_cand)) return fail("realpath failed");
    const char *suffix =
        "Baldurs Gate 3/Baldur's Gate 3.app/Contents/MacOS/Baldur's Gate 3";
    size_t rl = strlen(real_cand), sl = strlen(suffix);
    if (rl < sl || strcmp(real_cand + rl - sl, suffix) != 0) {
        return fail("target is not a BG3 binary");
    }

    // 4. 前置注入，保留已有 DYLD_INSERT_LIBRARIES
    const char *existing = getenv("DYLD_INSERT_LIBRARIES");
    char inject[PATH_MAX * 3];
    if (existing && existing[0]) {
        snprintf(inject, sizeof(inject), "%s:%s", dylib, existing);
    } else {
        snprintf(inject, sizeof(inject), "%s", dylib);
    }
    setenv("DYLD_INSERT_LIBRARIES", inject, 1);

    // 4b. 可选调试环境文件 launch_env，每行 KEY=VALUE（排障开关用）。
    // 查找顺序：$BG3MF_HOME/runs → <包装器目录>/../runs（开发布局）→ 默认 home。
    {
        char env_file[PATH_MAX * 2];
        FILE *ef = NULL;
        const char *hh = getenv("BG3MF_HOME");
        if (hh && hh[0]) {
            snprintf(env_file, sizeof(env_file), "%s/runs/launch_env", hh);
            ef = fopen(env_file, "r");
        }
        if (!ef) {
            snprintf(env_file, sizeof(env_file), "%s/runs/launch_env", selfdir);
            ef = fopen(env_file, "r");
        }
        if (!ef) {
            snprintf(env_file, sizeof(env_file), "%s/../runs/launch_env", selfdir);
            ef = fopen(env_file, "r");
        }
        if (!ef) {
            char home[PATH_MAX];
            bg3mf_home(home, sizeof(home));
            snprintf(env_file, sizeof(env_file), "%s/runs/launch_env", home);
            ef = fopen(env_file, "r");
        }
        if (ef) {
            char line[512];
            while (fgets(line, sizeof(line), ef)) {
                char *eq = strchr(line, '=');
                if (!eq) continue;
                *eq = '\0';
                char *v = eq + 1;
                v[strcspn(v, "\r\n")] = '\0';
                if (line[0] && line[0] != '#') setenv(line, v, 1);
            }
            fclose(ef);
        }
    }

    log_event("inject target validated");

    // 5. exec 目标，参数透传
    char **child_argv = calloc((size_t)(argc - consumed) + 1, sizeof(char *));
    if (!child_argv) return fail("oom");
    child_argv[0] = candidate;
    for (int i = consumed + 1; i < argc; i++) {
        child_argv[i - consumed] = argv[i];
    }
    child_argv[argc - consumed] = NULL;
    execv(candidate, child_argv);
    int e = errno;
    (void)e;
    return fail("execv failed");
}
