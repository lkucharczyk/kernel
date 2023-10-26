ENTRY(_start)

ADDR_KMAIN_OFFSET = 0xc0000000;

SECTIONS {
	. = 1M;
	ADDR_KBOOT_START = .;

	.rodata.boot : {
		KEEP(*(.multiboot))
	}

	.text.boot : {
		*(.text.boot)
	}

	ADDR_KBOOT_END = .;
	. += ADDR_KMAIN_OFFSET;
	ADDR_KMAIN_START = .;

	.text ALIGN(4K) : AT(ADDR(.text) - ADDR_KMAIN_OFFSET) {
		*(.text)
	}

	.rodata ALIGN(4K) : AT(ADDR(.rodata) - ADDR_KMAIN_OFFSET) {
		*(.rodata)
	}

	.data ALIGN(4K) : AT(ADDR(.data) - ADDR_KMAIN_OFFSET) {
		*(.data)
	}

	.bss ALIGN(4K) : AT(ADDR(.bss) - ADDR_KMAIN_OFFSET) {
		*(COMMON)
		*(.bss)
		ADDR_KSTACK_START = .;
		KEEP(*(.bss.kstack))
		ADDR_KSTACK_END = .;
	}

	ADDR_KMAIN_END = .;
}
