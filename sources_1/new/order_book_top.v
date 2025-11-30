`include "order_defines.v"

module order_book_top (
    input wire clk,
    input wire rst_n,

    // --- External Interface (UDP/Strategy) ---
    input wire input_valid,
    input wire [31:0] input_data, // {Price, IsBuy, ID, Qty}

    // --- Status / Debug ---
    output wire engine_busy,
    output wire [3:0] leds,       // [3]=AskFull, [2]=BidFull, [1]=AskEmpty, [0]=BidEmpty

    // --- Trade Reporting Output ---
    output wire trade_valid,
    output wire [31:0] trade_info // {Price, ID, Qty}
);

    // =========================================================================
    // Internal Wires (The "Nerve Center")
    // =========================================================================

    // --- Bid Side Connections ---
    wire [1:0]  bid_cmd;
    wire [31:0] bid_data_to_heap;
    wire [31:0] bid_root;
    wire        bid_empty;
    wire        bid_full;
    wire        bid_done;
    
    // Bid BRAM Connections
    wire        bid_ram_we;
    wire [9:0]  bid_ram_addr;
    wire [31:0] bid_ram_wdata;
    wire [31:0] bid_ram_rdata;

    // --- Ask Side Connections ---
    wire [1:0]  ask_cmd;
    wire [31:0] ask_data_to_heap;
    wire [31:0] ask_root;
    wire        ask_empty;
    wire        ask_full;
    wire        ask_done;

    // Ask BRAM Connections
    wire        ask_ram_we;
    wire [9:0]  ask_ram_addr;
    wire [31:0] ask_ram_wdata;
    wire [31:0] ask_ram_rdata;

    // =========================================================================
    // 1. The Matching Engine (The Brain)
    // =========================================================================
    matching_engine u_engine (
        .clk            (clk),
        .rst_n          (rst_n),
        
        // Input
        .input_valid    (input_valid),
        .input_data     (input_data),
        .engine_busy    (engine_busy),

        // Bid Heap Interface
        .bid_root       (bid_root),
        .bid_empty      (bid_empty),
        .bid_done       (bid_done),
        .bid_cmd        (bid_cmd),
        .bid_data_out   (bid_data_to_heap),

        // Ask Heap Interface
        .ask_root       (ask_root),
        .ask_empty      (ask_empty),
        .ask_done       (ask_done),
        .ask_cmd        (ask_cmd),
        .ask_data_out   (ask_data_to_heap),

        // Output
        .trade_valid    (trade_valid),
        .trade_info     (trade_info)
    );

    // =========================================================================
    // 2. The Bid Side (Max Heap + BRAM)
    // =========================================================================
    heap_manager #(
        .HEAP_TYPE(`TYPE_BID) // 1 = Max Heap (High Price Priority)
    ) u_bid_heap (
        .clk        (clk),
        .rst_n      (rst_n),
        .cmd        (bid_cmd),
        .data_in    (bid_data_to_heap),
        .root_out   (bid_root),
        .count      (), // Unused port
        .full       (bid_full),
        .empty      (bid_empty),
        .busy       (), // Engine handles wait states via 'done'
        .done       (bid_done),
        
        // BRAM Interface
        .we         (bid_ram_we),
        .addr       (bid_ram_addr),
        .wdata      (bid_ram_wdata),
        .rdata      (bid_ram_rdata)
    );

    simple_bram u_bid_ram (
        .clk    (clk),
        .we     (bid_ram_we),
        .addr   (bid_ram_addr),
        .wdata  (bid_ram_wdata),
        .rdata  (bid_ram_rdata)
    );

    // =========================================================================
    // 3. The Ask Side (Min Heap + BRAM)
    // =========================================================================
    heap_manager #(
        .HEAP_TYPE(`TYPE_ASK) // 0 = Min Heap (Low Price Priority)
    ) u_ask_heap (
        .clk        (clk),
        .rst_n      (rst_n),
        .cmd        (ask_cmd),
        .data_in    (ask_data_to_heap),
        .root_out   (ask_root),
        .count      (),
        .full       (ask_full),
        .empty      (ask_empty),
        .busy       (),
        .done       (ask_done),
        
        // BRAM Interface
        .we         (ask_ram_we),
        .addr       (ask_ram_addr),
        .wdata      (ask_ram_wdata),
        .rdata      (ask_ram_rdata)
    );

    simple_bram u_ask_ram (
        .clk    (clk),
        .we     (ask_ram_we),
        .addr   (ask_ram_addr),
        .wdata  (ask_ram_wdata),
        .rdata  (ask_ram_rdata)
    );

    // =========================================================================
    // Debug Logic
    // =========================================================================
    assign leds = {ask_full, bid_full, ask_empty, bid_empty};

endmodule