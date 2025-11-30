// Bit Widths
`define ADDR_WIDTH 10
`define DATA_WIDTH 32

// Bit Slicing Macros (The "Struct" replacement)
// Usage: `PRICE(my_data_reg)
`define PRICE(x) x[31:16]
`define IS_BOT(x) x[15]
`define QTY(x)   x[14:0]

// Command Codes (Enum replacement)
`define CMD_NOP    2'b00
`define CMD_PUSH   2'b01
`define CMD_POP    2'b10
`define CMD_UPDATE 2'b11

// Heap Type
`define TYPE_BID 1'b1 // Max Heap
`define TYPE_ASK 1'b0 // Min Heap