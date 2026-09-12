// FSR1 画质档位 ratio 表运行时补丁（阶段 E2 前置）。
//
// 游戏内建表（__DATA_CONST，arm64 VA 0x10873a070）为官方 FSR1 四档：
//   极高品质=1.3x  品质=1.5x  平衡=1.7x  性能=2.0x
// 实测确认 mode=2（平衡）→ 内部渲染 3456/1.7=2032。
// 按需求改为"每档降一级"的 MetalFX 映射：
//   极高品质→1.5x(67%)  品质→1.7x(59%)  平衡→2.0x(50%)  性能→2.9412x(34%)
//
// 方法：按 MH_EXECUTE 找主映像，加 slide 得表址，先校验原值再 vm_protect 写入。
// 开关：BG3MF_SCALE_PATCH=1（默认关闭，不影响原生 FSR1）。
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach/vm_prot.h>
#include <mach/mach.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

void bg3mf_observer_log(const char *msg);

// 表的 arm64 静态 VA（交接研究核实，见 HANDOFF）
#define BG3_FSR1_TABLE_STATIC_VA 0x10873a070ULL

static const float kOrigTable[4] = {1.3f, 1.5f, 1.7f, 2.0f};
static const float kPatchTable[4] = {1.5f, 1.7f, 2.0f, 2.9411765f};

void bg3mf_scale_patch_install(void) {
    const char *e = getenv("BG3MF_SCALE_PATCH");
    if (!e || strcmp(e, "1") != 0) return;

    const struct mach_header_64 *exec = NULL;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header_64 *h =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (h && h->filetype == MH_EXECUTE) { exec = h; break; }
    }
    if (!exec) {
        bg3mf_observer_log("scalepatch: no MH_EXECUTE");
        return;
    }
    long slide = -1;
    for (uint32_t i = 0; i < n; i++) {
        if (_dyld_get_image_header(i) == (const struct mach_header *)exec) {
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    float *tab = (float *)(uintptr_t)(BG3_FSR1_TABLE_STATIC_VA + slide);
    if (memcmp(tab, kOrigTable, sizeof(kOrigTable)) != 0) {
        bg3mf_observer_log("scalepatch: table content mismatch, skip");
        return;
    }
    mach_vm_address_t addr = (mach_vm_address_t)tab;
    mach_vm_size_t size = sizeof(kPatchTable);
    kern_return_t kr = vm_protect(mach_task_self(), addr, size, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        bg3mf_observer_log("scalepatch: vm_protect failed");
        return;
    }
    memcpy(tab, kPatchTable, size);
    vm_protect(mach_task_self(), addr, size, FALSE, VM_PROT_READ);
    bg3mf_observer_log("scalepatch: FSR1 ratio table patched -> 1.5/1.7/2.0/2.9412");
}
