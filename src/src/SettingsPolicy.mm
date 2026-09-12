// Build-specific, checked in-memory policy for native Steam 4.1.1.7398727.
// FSR1 is the UI transport for MetalFX. Keep its required TAA stage selected,
// prevent manual AA overrides, and let the game's own enabled-change event gray it.
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libkern/OSCacheControl.h>
#include <cstring>
#include <cstdlib>
#include <vector>

void bg3mf_observer_log(const char *);
struct Patch { uint64_t va; unsigned count; uint32_t original[3], replacement[3]; };
static const Patch patches[] = {
    // RefreshUIAntiAliasing: enabled iff upscale type is Off (0).
    {0x103292780,3,{0xb9409e88,0x7100051f,0x1a9fd7e8},{0x39c3de68,0x7100011f,0x1a9f17e8}},
    // SetResolutionUpscaleFSR1: always choose TAA (2), including from Off/SMAA.
    {0x10640dffc,1,{0x54fffe42},{0x17fffff2}},
    // ApplyComboBox: the FSR-specific AA path cannot overwrite the forced TAA.
    {0x1032903ac,2,{0x7100091f,0x540003e8},{0x52800048,0xd503201f}},
    // LoadGraphicSettingsConfig: normalize saved FSR AA to TAA before rendering.
    // Off branches to the original native-AA path at 0x105d117bc.
    {0x105d117a8,3,{0x340000ab,0x7100099f,0x540001a8},{0x7100057f,0x54000081,0x5280004c}},
    // SetResolutionUpscaleFSR1: zero sharpness on every selection, even the same tier.
    {0x10640dfd0,2,{0x6b21011f,0x54000080},{0xb9009c1f,0xd65f03c0}},
    // Config FSR path: zero sharpness, then fall through the native check. Forced
    // w12=2 and w11=1 make that check branch to the original continuation.
    {0x105d117b8,1,{0x1400000b},{0xb9009d5f}},
    // ApplySlider's dedicated upscale-sharpness store cannot restore a nonzero value.
    {0x1032906b0,1,{0xbd00fc00},{0xb900fc1f}},
    // Upscale sharpness enabled mask: remove FSR1's bit; native Off stays disabled.
    {0x103294b4c,1,{0x528001ca},{0x5280018a}},
    // InitOptions and ResetOptions initialize the same slider enabled mask.
    {0x10328bfec,1,{0x528001ca},{0x5280018a}},
    {0x10328f2e0,1,{0x528001ca},{0x5280018a}},
};

void bg3mf_settings_policy_install(void) {
    const char *temporal=getenv("BG3MF_TEMPORAL");
    if (!temporal || strcmp(temporal,"1")!=0) return;
    const char *policy=getenv("BG3MF_AA_POLICY");
    if (policy && strcmp(policy,"0")==0) return;
    const mach_header_64 *main=nullptr; intptr_t slide=0;
    for(uint32_t i=0;i<_dyld_image_count();++i) {
        auto *h=(const mach_header_64*)_dyld_get_image_header(i);
        if(h && h->magic==MH_MAGIC_64 && h->filetype==MH_EXECUTE) {
            main=h;slide=_dyld_get_image_vmaddr_slide(i);break;
        }
    }
    if(!main)return;
    std::vector<mach_vm_address_t> pages;
    for(const auto &p:patches) {
        bool mapped=false;auto *lc=(const load_command*)(main+1);
        for(uint32_t i=0;i<main->ncmds;++i) {
            if(lc->cmd==LC_SEGMENT_64) {
                auto *seg=(const segment_command_64*)lc;
                if((seg->initprot&(VM_PROT_READ|VM_PROT_EXECUTE))==(VM_PROT_READ|VM_PROT_EXECUTE) &&
                   p.va>=seg->vmaddr && p.va-seg->vmaddr<=seg->vmsize &&
                   seg->vmsize-(p.va-seg->vmaddr)>=p.count*4) mapped=true;
            }
            lc=(const load_command*)((const char*)lc+lc->cmdsize);
        }
        auto address=(mach_vm_address_t)(p.va+slide);
        if(!mapped || memcmp((const void*)address,p.original,p.count*4)!=0) {
            bg3mf_observer_log("AA policy: unsupported executable; no instructions changed");return;
        }
        auto page=address & ~((mach_vm_address_t)vm_page_size-1);
        bool found=false;for(auto v:pages)if(v==page)found=true;
        if(!found)pages.push_back(page);
    }
    size_t writable=0;
    for(auto page:pages) {
        if(mach_vm_protect(mach_task_self(),page,vm_page_size,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)!=KERN_SUCCESS) {
            for(size_t i=0;i<writable;++i)mach_vm_protect(mach_task_self(),pages[i],vm_page_size,FALSE,VM_PROT_READ|VM_PROT_EXECUTE);
            bg3mf_observer_log("AA policy: cannot prepare code pages; no instructions changed");return;
        }
        ++writable;
    }
    for(const auto &p:patches) {
        void *address=(void*)(p.va+slide);memcpy(address,p.replacement,p.count*4);sys_icache_invalidate(address,p.count*4);
    }
    for(auto page:pages) {
        if(mach_vm_protect(mach_task_self(),page,vm_page_size,FALSE,VM_PROT_READ|VM_PROT_EXECUTE)!=KERN_SUCCESS) {
            bg3mf_observer_log("AA policy: failed to restore execute permission");return;
        }
    }
    bg3mf_observer_log("AA policy: MetalFX forces TAA and zero sharpness; both controls locked");
}
