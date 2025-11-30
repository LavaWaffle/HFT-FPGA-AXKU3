// Bit Widths
`define ADDR_WIDTH 10
`define DATA_WIDTH 32

// Bit Slicing Macros (The "Struct" replacement)
// Usage: `PRICE(my_data_reg)
`define PRICE(x)  x[31:16]
`define IS_BUY(x) x[15]     // Bit 15 is now Side
`define IS_BOT(x) x[14]     // Bit 14 is now ID
`define QTY(x)    x[13:0]   // Bits 13-0 are Quantity

// Command Codes (Enum replacement)
`define CMD_NOP    2'b00
`define CMD_PUSH   2'b01
`define CMD_POP    2'b10
`define CMD_UPDATE 2'b11

// Heap Type
`define TYPE_BID 1'b1 // Max Heap
`define TYPE_ASK 1'b0 // Min Heap