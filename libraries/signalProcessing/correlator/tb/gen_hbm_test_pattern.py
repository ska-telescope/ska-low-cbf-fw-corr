#!/usr/bin/env python3
"""
FPGA Memory Initialization Generator – Dual Triangle with Tiles
===============================================================
Hierarchy:
  - 16x16 entries  = cell
  - 16x16 cells    = tile
  - Tiles arranged in a triangle: tile row t has t tiles.

Cells are stored sequentially in memory following the global triangle.
There is NO padding between cells; the address of cell N is simply
N * cell_size (in words).  This keeps the file dense and preserves
the original behaviour for small targets.

Section 1 (base 0x00000000): 32-byte entries, one matrix row per line.
Section 2 (base 0x04000000): 2-byte entries, one cell per line (512 bytes).
"""

import math

# ---------------------------------------------------------------------------
# Geometry constants
# ---------------------------------------------------------------------------
ROWS_PER_CELL = 16          # Matrix rows per cell
COLS_PER_CELL = 16          # Matrix columns per cell
CELL_ROWS_PER_TILE = 16     # Cell rows per tile
CELL_COLS_PER_TILE = 16     # Cell columns per tile

# ---------------------------------------------------------------------------
# User configurable target
# ---------------------------------------------------------------------------
TARGET_GLOBAL_ROW = 260     # Global triangle height (rows)

# ---------------------------------------------------------------------------
# Section 1 parameters (32-byte entries, one row per line)
# ---------------------------------------------------------------------------
BYTES_PER_ENTRY_1 = 32
BYTES_PER_ROW_1 = COLS_PER_CELL * BYTES_PER_ENTRY_1      # 512 bytes
WORDS_PER_ROW_1 = BYTES_PER_ROW_1 // 4                    # 128 words
WORDS_PER_CELL_1 = WORDS_PER_ROW_1 * ROWS_PER_CELL        # 0x800 words
ADDR_BASE_1 = 0x00000000

# ---------------------------------------------------------------------------
# Section 2 parameters (2-byte entries, one cell per line)
# ---------------------------------------------------------------------------
BYTES_PER_ENTRY_2 = 2
BYTES_PER_ROW_2 = COLS_PER_CELL * BYTES_PER_ENTRY_2      # 32 bytes
WORDS_PER_ROW_2 = BYTES_PER_ROW_2 // 4                    # 8 words
WORDS_PER_CELL_2 = WORDS_PER_ROW_2 * ROWS_PER_CELL        # 0x80 words
ADDR_BASE_2 = 0x04000000


def compute_geometry(target_global_row: int):
    """Derive cell rows and tile rows from the target global row."""
    cell_rows_needed = (target_global_row + ROWS_PER_CELL - 1) // ROWS_PER_CELL
    tile_rows = (cell_rows_needed + CELL_ROWS_PER_TILE - 1) // CELL_ROWS_PER_TILE
    total_cells = cell_rows_needed * (cell_rows_needed + 1) // 2
    total_tiles = tile_rows * (tile_rows + 1) // 2
    return cell_rows_needed, tile_rows, total_cells, total_tiles


def generate_section_1(f, cell_rows_needed: int, tile_rows: int):
    """32-byte entries: one matrix row per output line (512 bytes)."""
    cell_counter = 0  # sequential cell index, determines base address

    for tile_row in range(1, tile_rows + 1):
        for tile_col in range(1, tile_row + 1):
            # Cell rows covered by this tile (clipped to target)
            cr_start = (tile_row - 1) * CELL_ROWS_PER_TILE + 1
            cr_end = min(tile_row * CELL_ROWS_PER_TILE, cell_rows_needed)

            # Cell columns covered by this tile
            cc_start = (tile_col - 1) * CELL_COLS_PER_TILE + 1
            cc_end = tile_col * CELL_COLS_PER_TILE

            for cr in range(cr_start, cr_end + 1):
                # Triangle clipping: only cells with col <= row are real
                actual_cc_end = min(cc_end, cr)
                if actual_cc_end < cc_start:
                    continue

                for cc in range(cc_start, actual_cc_end + 1):
                    base_addr_field = ADDR_BASE_1 + cell_counter * WORDS_PER_CELL_1
                    global_row_base = (cr - 1) * ROWS_PER_CELL
                    global_col_base = (cc - 1) * COLS_PER_CELL

                    for lr in range(ROWS_PER_CELL):
                        global_row = global_row_base + lr + 1
                        addr_field = base_addr_field + lr * WORDS_PER_ROW_1
                        tokens = [f"{addr_field:08x}"]

                        for lc in range(COLS_PER_CELL):
                            global_col = global_col_base + lc + 1
                            if global_col <= global_row:
                                word = f"{global_col:04x}{global_row:04x}"
                            else:
                                word = "00000000"
                            # Repeat the 4-byte word 8 times for the 32-byte entry
                            tokens.extend([word] * (BYTES_PER_ENTRY_1 // 4))

                        f.write(" ".join(tokens) + "\n")

                    cell_counter += 1


def generate_section_2(f, cell_rows_needed: int, tile_rows: int):
    """
    2-byte entries: one full cell per output line (512 bytes / 128 words).
    Active entry: [0xFF][column_low_byte]. Inactive entry: 0x0000.
    Two entries pack into one 4-byte word.
    """
    cell_counter = 0

    for tile_row in range(1, tile_rows + 1):
        for tile_col in range(1, tile_row + 1):
            cr_start = (tile_row - 1) * CELL_ROWS_PER_TILE + 1
            cr_end = min(tile_row * CELL_ROWS_PER_TILE, cell_rows_needed)
            cc_start = (tile_col - 1) * CELL_COLS_PER_TILE + 1
            cc_end = tile_col * CELL_COLS_PER_TILE

            for cr in range(cr_start, cr_end + 1):
                actual_cc_end = min(cc_end, cr)
                if actual_cc_end < cc_start:
                    continue

                for cc in range(cc_start, actual_cc_end + 1):
                    addr_field = ADDR_BASE_2 + cell_counter * WORDS_PER_CELL_2
                    global_row_base = (cr - 1) * ROWS_PER_CELL
                    global_col_base = (cc - 1) * COLS_PER_CELL

                    words = []
                    for lr in range(ROWS_PER_CELL):
                        global_row = global_row_base + lr + 1

                        entries = []
                        for lc in range(COLS_PER_CELL):
                            global_col = global_col_base + lc + 1
                            if global_col <= global_row:
                                col_byte = global_col & 0xFF
                                entries.append(f"ff{col_byte:02x}")
                            else:
                                entries.append("0000")

                        # Pack pairs of 2-byte entries into 4-byte words
                        for i in range(0, len(entries), 2):
                            words.append(entries[i] + entries[i + 1])

                    assert len(words) == 128
                    tokens = [f"{addr_field:08x}"] + words
                    f.write(" ".join(tokens) + "\n")

                    cell_counter += 1


def main():
    cell_rows_needed, tile_rows, total_cells, total_tiles = compute_geometry(TARGET_GLOBAL_ROW)

    with open("../../../../fpga_init.txt", "w") as f:
        generate_section_1(f, cell_rows_needed, tile_rows)
        generate_section_2(f, cell_rows_needed, tile_rows)

    print(f"Output file         : ../../../../fpga_init.txt")
    print(f"Target global row   : {TARGET_GLOBAL_ROW}")
    print(f"Cell rows generated : {cell_rows_needed}")
    print(f"Tile rows generated : {tile_rows}")
    print(f"Total tiles         : {total_tiles}")
    print(f"Total cells         : {total_cells}")
    print()
    print("Section 1 (32-byte entries, one matrix row per line):")
    print(f"  Lines             : {total_cells * ROWS_PER_CELL}")
    print(f"  Start addr field  : 0x{ADDR_BASE_1:08x}")
    print(f"  Address stride    : 0x80 per line, 0x800 per cell")
    print()
    print("Section 2 (2-byte entries, one cell per line):")
    print(f"  Lines             : {total_cells}")
    print(f"  Start addr field  : 0x{ADDR_BASE_2:08x}")
    print(f"  Address stride    : 0x80 per cell")
    print(f"  Entry format      : FF <col&0xFF>")


if __name__ == "__main__":
    main()
