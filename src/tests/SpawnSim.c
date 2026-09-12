// 模拟 Larian 启动器行为：复制 environ 并剔除 DYLD_INSERT_LIBRARIES，
// 然后以含 "Baldur's Gate 3" 的路径 posix_spawn 子进程。
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

int main(void) {
    size_t n = 0;
    while (environ[n]) n++;
    char **copy = malloc((n + 1) * sizeof(char *));
    if (!copy) return 2;
    size_t out = 0;
    for (size_t i = 0; i < n; i++) {
        if (!strstr(environ[i], "DYLD_INSERT_LIBRARIES")) {
            copy[out++] = environ[i];
        }
    }
    copy[out] = NULL;

    char *const argv[] = {"/tmp/bg3mf_sim/Baldur's Gate 3", NULL};
    pid_t pid;
    int rc = posix_spawn(&pid, argv[0], NULL, NULL, argv, copy);
    if (rc) {
        fprintf(stderr, "spawn rc=%d\n", rc);
        return 1;
    }
    int st = 0;
    waitpid(pid, &st, 0);
    free(copy);
    return 0;
}
