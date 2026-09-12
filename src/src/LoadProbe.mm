// bg3-metalfx 阶段 A：加载探针 + posix_spawn 传播桥。
//
// 职责一（探针）：constructor 向项目 runs/ 写一行受控加载标记。
// 职责二（传播桥）：逆向证据显示 Larian 启动器在 posix_spawn 游戏本体前
//   会遍历 environ 并用 strstr 剔除所有含 "DYLD_INSERT_LIBRARIES" 的条目
//   （主映像 0x100b99dec-0x100b99e6c，envp 为过滤后副本）。
//   因此在主映像内重绑定 posix_spawn 导入：当目标是 BG3 游戏路径时，
//   把本 dylib 重新加入子进程 envp 的 DYLD_INSERT_LIBRARIES，其余调用原样透传。
//
// 不 hook 游戏内部函数、不修改游戏文件、不读取启动参数全文。
// constructor 处于 dyld 上下文，仅使用 C/POSIX 接口。

#include <dlfcn.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/vm_param.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#include <dispatch/dispatch.h>

#import <Foundation/Foundation.h>

// MetalObserver.mm 提供；构造后延迟安装，避免在 dyld 上下文初始化 Metal。
extern void bg3mf_observer_install(void);

// ---------------------------------------------------------------------------
// 未捕获异常诊断：游戏内 ObjC 异常会导致 SIGABRT 且原因不进 .ips。
// 延迟安装（等游戏自带 PLCrashReporter 先装好），记录异常名/原因后链接原 handler。
// ---------------------------------------------------------------------------
static void bg3mf_log(const char *tag, const char *detail);
static NSUncaughtExceptionHandler *g_prev_exc_handler = NULL;

static void bg3mf_uncaught_handler(NSException *exc) {
    char detail[2048];
    snprintf(detail, sizeof(detail), "name=%s reason=%s",
             exc ? [[exc name] UTF8String] : "(nil)",
             exc ? ([[exc reason] UTF8String] ?: "(null)") : "(nil)");
    bg3mf_log("BG3MF_UNCAUGHT", detail);
    if (g_prev_exc_handler) {
        g_prev_exc_handler(exc);
    }
}

static void bg3mf_install_exc_handler(void) {
    if (getenv("BG3MF_DISABLE_EXC_HOOK") != NULL) return;
    g_prev_exc_handler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(bg3mf_uncaught_handler);
    bg3mf_log("BG3MF_EXC_HOOK", "installed");
}

#define BG3MF_PROBE_BUILD_ID "bg3-metalfx-1.0.2 " __DATE__ " " __TIME__

// 运行根目录：BG3MF_HOME 环境变量优先，默认 ~/Library/Application Support/BG3MetalFX。
// 日志/哨兵/抓取等全部派生自此；开发时可用 BG3MF_HOME 指向项目 runs 的父目录。
const char *bg3mf_home(void) {
    static char g_home[PATH_MAX] = {0};
    if (g_home[0] == '\0') {
        const char *h = getenv("BG3MF_HOME");
        if (h && h[0]) {
            snprintf(g_home, sizeof(g_home), "%s", h);
        } else {
            const char *home = getenv("HOME");
            snprintf(g_home, sizeof(g_home),
                     "%s/Library/Application Support/BG3MetalFX",
                     home ? home : ".");
        }
    }
    return g_home;
}

static char g_self_path[PATH_MAX] = {0};

// ---------------------------------------------------------------------------
// 日志：单行追加，失败静默（不得影响宿主）。
// ---------------------------------------------------------------------------
static void bg3mf_log(const char *tag, const char *detail) {
    const char *log_path = getenv("BG3MF_PROBE_LOG");
    char def_path[PATH_MAX];
    if (log_path == NULL || log_path[0] == '\0') {
        snprintf(def_path, sizeof(def_path), "%s/runs/loadprobe.log",
                 bg3mf_home());
        log_path = def_path;
    }
    int fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) {
        return;
    }
    struct timeval tv;
    gettimeofday(&tv, NULL);
    char line[4096];
    int n = snprintf(line, sizeof(line), "%s ts=%lld.%06d pid=%d ppid=%d %s\n",
                     tag, (long long)tv.tv_sec, (int)tv.tv_usec,
                     (int)getpid(), (int)getppid(), detail ? detail : "");
    if (n > 0) {
        size_t len = (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1;
        ssize_t ignored = write(fd, line, len);
        (void)ignored;
    }
    close(fd);
}

static void bg3mf_probe_write(void) {
    char exe_path[PROC_PIDPATHINFO_MAXSIZE];
    exe_path[0] = '\0';
    if (proc_pidpath(getpid(), exe_path, sizeof(exe_path)) <= 0) {
        exe_path[0] = '\0';
    }
    char detail[4200];
    snprintf(detail, sizeof(detail), "exe=\"%s\" dylib=\"%s\" build=\"%s\"",
             exe_path, g_self_path, BG3MF_PROBE_BUILD_ID);
    bg3mf_log("BG3MF_LOAD_PROBE", detail);
}

// ---------------------------------------------------------------------------
// posix_spawn 挂钩：仅对 BG3 游戏路径补回 DYLD_INSERT_LIBRARIES。
// ---------------------------------------------------------------------------
static int (*g_orig_posix_spawn)(pid_t *, const char *,
                                 const posix_spawn_file_actions_t *,
                                 const posix_spawnattr_t *,
                                 char *const argv[], char *const envp[]) = NULL;

static char **bg3mf_env_with_insert(char *const envp[]) {
    extern char **environ;
    char *const *src = envp ? envp : environ;

    size_t count = 0;
    while (src[count] != NULL) count++;

    char **copy = (char **)malloc((count + 2) * sizeof(char *));
    if (!copy) return NULL;

    const char *key = "DYLD_INSERT_LIBRARIES";
    size_t key_len = strlen(key);
    int found = 0;
    size_t out = 0;
    for (size_t i = 0; i < count; i++) {
        if (strncmp(src[i], key, key_len) == 0 && src[i][key_len] == '=') {
            found = 1;
            if (strstr(src[i], g_self_path) == NULL) {
                // 已有其他插入库：追加本 dylib。
                size_t need = strlen(src[i]) + 1 + strlen(g_self_path) + 1;
                char *merged = (char *)malloc(need);
                if (merged) {
                    snprintf(merged, need, "%s:%s", src[i], g_self_path);
                    copy[out++] = merged;
                    continue;
                }
            }
        }
        copy[out++] = src[i];
    }
    if (!found) {
        size_t need = key_len + 1 + strlen(g_self_path) + 1;
        char *entry = (char *)malloc(need);
        if (entry) {
            snprintf(entry, need, "%s=%s", key, g_self_path);
            copy[out++] = entry;
        }
    }
    copy[out] = NULL;
    return copy;
}

static void bg3mf_env_free(char *const envp[], char **copy) {
    if (!copy) return;
    extern char **environ;
    char *const *src = envp ? envp : environ;
    for (size_t i = 0; copy[i] != NULL; i++) {
        // 仅释放本函数新分配的字符串。
        int from_src = 0;
        for (size_t j = 0; src[j] != NULL; j++) {
            if (src[j] == copy[i]) { from_src = 1; break; }
        }
        if (!from_src) free(copy[i]);
    }
    free(copy);
}

static int bg3mf_posix_spawn(pid_t *pid, const char *path,
                             const posix_spawn_file_actions_t *fa,
                             const posix_spawnattr_t *attr,
                             char *const argv[], char *const envp[]) {
    if (path != NULL && strstr(path, "Baldur's Gate 3") != NULL &&
        g_self_path[0] != '\0') {
        char **fixed = bg3mf_env_with_insert(envp);
        char detail[4200];
        snprintf(detail, sizeof(detail),
                 "spawn path=\"%s\" envp=%s reinject=%s",
                 path, envp ? "custom" : "inherit",
                 fixed ? "ok" : "alloc-failed");
        bg3mf_log("BG3MF_SPAWN_BRIDGE", detail);
        int rc = g_orig_posix_spawn(pid, path, fa, attr, argv,
                                    fixed ? fixed : envp);
        bg3mf_env_free(envp, fixed);
        return rc;
    }
    return g_orig_posix_spawn(pid, path, fa, attr, argv, envp);
}

// ---------------------------------------------------------------------------
// 主映像 posix_spawn 导入重绑定（fishhook 原理的最小实现，仅 image 0）。
// __DATA_CONST 页被 dyld 写保护，替换前临时放开写权限。
// ---------------------------------------------------------------------------
static int bg3mf_rebind_in_sections(const struct segment_command_64 *seg,
                                    intptr_t slide,
                                    const struct nlist_64 *symtab,
                                    const char *strtab,
                                    const uint32_t *indirect) {
    int rebound = 0;
    const struct section_64 *sect =
        (const struct section_64 *)((const char *)seg + sizeof(struct segment_command_64));
    for (uint32_t s = 0; s < seg->nsects; s++) {
        uint32_t flags = sect[s].flags & SECTION_TYPE;
        if (flags != S_LAZY_SYMBOL_POINTERS && flags != S_NON_LAZY_SYMBOL_POINTERS) {
            continue;
        }
        uint32_t base = sect[s].reserved1;
        size_t count = sect[s].size / sizeof(void *);
        void **slots = (void **)(uintptr_t)(slide + sect[s].addr);
        for (size_t i = 0; i < count; i++) {
            uint32_t idx = indirect[base + i];
            if (idx == INDIRECT_SYMBOL_LOCAL || idx == INDIRECT_SYMBOL_ABS) {
                continue;
            }
            const char *name = strtab + symtab[idx].n_un.n_strx;
            if (getenv("BG3MF_DEBUG_REBIND") != NULL) {
                char dbg[160];
                snprintf(dbg, sizeof(dbg), "sect=%s i=%zu idx=%u name=%s",
                         sect[s].sectname, i, idx, name);
                bg3mf_log("BG3MF_REBIND_DEBUG", dbg);
            }
            if (strcmp(name, "_posix_spawn") != 0) {
                continue;
            }
            vm_address_t page = (vm_address_t)slots +
                (i * sizeof(void *)) - (((vm_address_t)slots + i * sizeof(void *)) % vm_page_size);
            if (vm_protect(mach_task_self(), page, vm_page_size, 0,
                           VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
                continue;
            }
            g_orig_posix_spawn = (__typeof(g_orig_posix_spawn))slots[i];
            slots[i] = (void *)&bg3mf_posix_spawn;
            vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ);
            rebound++;
        }
    }
    return rebound;
}

static void bg3mf_install_spawn_bridge(void) {
    if (getenv("BG3MF_DISABLE_SPAWN_HOOK") != NULL) {
        bg3mf_log("BG3MF_SPAWN_BRIDGE", "disabled by env");
        return;
    }
    // 注意：DYLD_INSERT_LIBRARIES 下 image 0 可能是被插入的 dylib 本身。
    // 必须按 MH_EXECUTE 定位主映像。
    const struct mach_header_64 *mh = NULL;
    intptr_t slide = 0;
    uint32_t image_count = _dyld_image_count();
    for (uint32_t i = 0; i < image_count; i++) {
        const struct mach_header_64 *cand =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (cand && cand->magic == MH_MAGIC_64 && cand->filetype == MH_EXECUTE) {
            mh = cand;
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    if (mh == NULL) {
        return;
    }

    const struct load_command *lc =
        (const struct load_command *)((const char *)mh + sizeof(struct mach_header_64));
    const struct segment_command_64 *linkedit = NULL;
    const struct segment_command_64 *segs[16];
    uint32_t nsegs = 0;
    const struct symtab_command *symtab_cmd = NULL;
    const struct dysymtab_command *dysymtab_cmd = NULL;

    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                linkedit = seg;
            } else if (strcmp(seg->segname, SEG_DATA) == 0 ||
                       strcmp(seg->segname, "__DATA_CONST") == 0) {
                if (nsegs < 16) segs[nsegs++] = seg;
            }
        } else if (lc->cmd == LC_SYMTAB) {
            symtab_cmd = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (const struct dysymtab_command *)lc;
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    if (!linkedit || !symtab_cmd || !dysymtab_cmd) {
        bg3mf_log("BG3MF_SPAWN_BRIDGE", "missing load commands");
        return;
    }

    uintptr_t linkedit_base =
        (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symtab =
        (const struct nlist_64 *)(linkedit_base + symtab_cmd->symoff);
    const char *strtab = (const char *)(linkedit_base + symtab_cmd->stroff);
    const uint32_t *indirect =
        (const uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

    int total = 0;
    for (uint32_t i = 0; i < nsegs; i++) {
        total += bg3mf_rebind_in_sections(segs[i], slide, symtab, strtab, indirect);
    }
    char detail[128];
    snprintf(detail, sizeof(detail), "installed sites=%d segs=%u symoff=%u indirectoff=%u",
             total, nsegs, symtab_cmd->symoff, dysymtab_cmd->indirectsymoff);
    bg3mf_log("BG3MF_SPAWN_BRIDGE", detail);
}

void bg3mf_scale_patch_install(void);
void bg3mf_settings_policy_install(void);

// ---------------------------------------------------------------------------
__attribute__((constructor)) static void bg3mf_probe_init(void) {
    Dl_info self_info;
    if (dladdr((const void *)&bg3mf_probe_init, &self_info) != 0 &&
        self_info.dli_fname != NULL) {
        snprintf(g_self_path, sizeof(g_self_path), "%s", self_info.dli_fname);
    }
    bg3mf_probe_write();
    bg3mf_install_spawn_bridge();
    bg3mf_settings_policy_install();
    bg3mf_scale_patch_install();  // 尽早：引擎首次创建渲染目标前

    // 阶段 B：只观测 Metal API。默认延迟 3s 避开 dyld/启动早期；
    // BG3MF_OBSERVER_DELAY_MS 可覆盖（自测时设为 0）。
    long delay_ms = 3000;
    const char *delay_env = getenv("BG3MF_OBSERVER_DELAY_MS");
    if (delay_env != NULL) {
        long v = atol(delay_env);
        if (v >= 0) delay_ms = v;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay_ms * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                       bg3mf_install_exc_handler();
                       bg3mf_observer_install();
                   });
}

// MetalObserver 的日志出口。
void bg3mf_observer_log(const char *msg) {
    bg3mf_log("BG3MF_OBSERVER", msg ? msg : "");
}

// MetalObserver 定位旁随 metallib 用。
const char *bg3mf_self_path(void) {
    return g_self_path;
}