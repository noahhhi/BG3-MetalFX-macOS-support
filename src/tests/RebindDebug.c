// 独立调试：对 image 0 做与 dylib 相同的重绑定遍历，打印各环节发现的内容。
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    const struct mach_header_64 *mh =
        (const struct mach_header_64 *)_dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    printf("mh=%p magic=%x ncmds=%u slide=%#lx\n", (void *)mh, mh->magic,
           mh->ncmds, (long)slide);

    const struct load_command *lc =
        (const struct load_command *)((const char *)mh + sizeof(struct mach_header_64));
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab_cmd = NULL;
    const struct dysymtab_command *dysymtab_cmd = NULL;

    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit = seg;
            printf("seg %-16s nsects=%u\n", seg->segname, seg->nsects);
            const struct section_64 *sect =
                (const struct section_64 *)((const char *)seg + sizeof(struct segment_command_64));
            for (uint32_t s = 0; s < seg->nsects; s++) {
                uint32_t flags = sect[s].flags & SECTION_TYPE;
                if (flags == S_LAZY_SYMBOL_POINTERS || flags == S_NON_LAZY_SYMBOL_POINTERS) {
                    printf("  ptrsect %-16s flags=%#x reserved1=%u count=%zu addr=%#llx\n",
                           sect[s].sectname, sect[s].flags, sect[s].reserved1,
                           (size_t)(sect[s].size / 8), sect[s].addr);
                }
            }
        } else if (lc->cmd == LC_SYMTAB) {
            symtab_cmd = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (const struct dysymtab_command *)lc;
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    printf("linkedit=%p symtab=%p dysymtab=%p\n", (void *)linkedit,
           (void *)symtab_cmd, (void *)dysymtab_cmd);
    if (!linkedit || !symtab_cmd || !dysymtab_cmd) return 1;

    uintptr_t linkedit_base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symtab =
        (const struct nlist_64 *)(linkedit_base + symtab_cmd->symoff);
    const char *strtab = (const char *)(linkedit_base + symtab_cmd->stroff);
    const uint32_t *indirect =
        (const uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);
    printf("nsyms=%u indirectsymoff=%u nindirect=%u\n", symtab_cmd->nsyms,
           dysymtab_cmd->indirectsymoff, dysymtab_cmd->nindirectsyms);

    // 第二遍：对每个指针段列出符号名。
    lc = (const struct load_command *)((const char *)mh + sizeof(struct mach_header_64));
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            const struct section_64 *sect =
                (const struct section_64 *)((const char *)seg + sizeof(struct segment_command_64));
            for (uint32_t s = 0; s < seg->nsects; s++) {
                uint32_t flags = sect[s].flags & SECTION_TYPE;
                if (flags != S_LAZY_SYMBOL_POINTERS && flags != S_NON_LAZY_SYMBOL_POINTERS)
                    continue;
                uint32_t base = sect[s].reserved1;
                size_t count = sect[s].size / sizeof(void *);
                for (size_t j = 0; j < count; j++) {
                    uint32_t idx = indirect[base + j];
                    if (idx == INDIRECT_SYMBOL_LOCAL || idx == INDIRECT_SYMBOL_ABS) continue;
                    const char *name = strtab + symtab[idx].n_un.n_strx;
                    printf("  slot %s[%zu] -> %s\n", sect[s].sectname, j, name);
                }
            }
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    (void)posix_spawn;
    return 0;
}
