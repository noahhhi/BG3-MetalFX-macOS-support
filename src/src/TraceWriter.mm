// bg3-metalfx 阶段 B：限量 JSONL 追踪写入器。
// 线程安全、失败静默；日志只写入项目 runs/，不影响被观测进程渲染。
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

static NSString *g_trace_path = nil;
static NSFileHandle *g_trace_handle = nil;
static pthread_mutex_t g_trace_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic unsigned long g_trace_lines = 0;
// 限量：默认最多 2,000,000 行，超出后停止写入（防止意外打满磁盘）。
static const unsigned long kMaxLines = 2000000;

void bg3mf_trace_init(const char *path) {
    pthread_mutex_lock(&g_trace_lock);
    @autoreleasepool {
        if (g_trace_handle) {
            pthread_mutex_unlock(&g_trace_lock);
            return;
        }
        g_trace_path = [[NSString alloc] initWithUTF8String:path];
        NSString *dir = [g_trace_path stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        [[NSFileManager defaultManager] createFileAtPath:g_trace_path
                                                contents:nil
                                              attributes:nil];
        g_trace_handle =
            [NSFileHandle fileHandleForWritingAtPath:g_trace_path];
    }
    pthread_mutex_unlock(&g_trace_lock);
}

// obj 须为可 JSON 序列化对象；失败时丢弃该行。
void bg3mf_trace_event(NSDictionary *obj) {
    if (atomic_fetch_add(&g_trace_lines, 1) >= kMaxLines) return;
    @autoreleasepool {
        NSData *data = [NSJSONSerialization dataWithJSONObject:obj
                                                       options:0
                                                         error:nil];
        if (!data) return;
        NSMutableData *line = [data mutableCopy];
        [line appendBytes:"\n" length:1];
        pthread_mutex_lock(&g_trace_lock);
        @try {
            [g_trace_handle writeData:line];
        } @catch (...) {
        }
        pthread_mutex_unlock(&g_trace_lock);
    }
}

unsigned long bg3mf_trace_lines(void) {
    return atomic_load(&g_trace_lines);
}
