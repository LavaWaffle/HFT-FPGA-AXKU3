`include "order_defines.v"

module order_book_top (
    input wire clk,
    input wire rst_n,

    // --- External Interface (UDP/Strategy) ---
    input wire input_valid,
    input wire [31:0] input_data, // {Price, IsBuy, ID, Qty}
    
    // NEW: Trigger from Payload Extractor
    input wire start_dump,

    // --- Status / Debug ---
    output wire engine_busy,
    output wire [3:0] leds,       // [3]=AskFull, [2]=BidFull, [1]=AskEmpty, [0]=BidEmpty

    // --- Trade Reporting Output ---
    output wire trade_valid,
    output wire [31:0] trade_info // {Price, ID, Qty}
);

    // =========================================================================
    // DUMP MODE SIGNALS
    // =========================================================================
    reg dumping_active;
    reg [9:0] dump_addr;
    
    // Output Mux Signals
    reg        dump_out_valid;
    reg [31:0] dump_out_data;
    wire       engine_out_valid;
    wire [31:0] engine_out_data;
    
    // Internal Busy Signal (from Matching Engine)
    wire internal_engine_busy;

    // =========================================================================
    // 1. The Matching Engine (The Brain)
    // =========================================================================
    
    // --- Bid Side Wire Intercepts ---
    // We separate "Heap" signals from "RAM" signals so we can MUX them
    wire [1:0]  bid_cmd;
    wire [31:0] bid_data_to_heap;
    wire [31:0] bid_root;
    wire        bid_empty, bid_full, bid_done;
    
    wire        heap_bid_we;
    wire [9:0]  heap_bid_addr;
    wire [31:0] heap_bid_wdata;
    wire [31:0] bid_ram_rdata; // Common read data

    // --- Ask Side Wire Intercepts ---
    wire [1:0]  ask_cmd;
    wire [31:0] ask_data_to_heap;
    wire [31:0] ask_root;
    wire        ask_empty, ask_full, ask_done;

    wire        heap_ask_we;
    wire [9:0]  heap_ask_addr;
    wire [31:0] heap_ask_wdata;
    wire [31:0] ask_ram_rdata; // Common read data

    matching_engine u_engine (
        .clk            (clk),
        .rst_n          (rst_n),
        
        // Input
        .input_valid    (input_valid && !dumping_active), // Block inputs during dump
        .input_data     (input_data),
        .engine_busy    (internal_engine_busy),

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

        // Output (Renamed to allow Muxing)
        .trade_valid    (engine_out_valid),
        .trade_info     (engine_out_data)
    );

    // =========================================================================
    // 2. The Bid Side (Max Heap + BRAM)
    // =========================================================================
    heap_manager #(
        .HEAP_TYPE(`TYPE_BID) 
    ) u_bid_heap (
        .clk        (clk),
        .rst_n      (rst_n),
        .cmd        (bid_cmd),
        .data_in    (bid_data_to_heap),
        .root_out   (bid_root),
        .count      (), 
        .full       (bid_full),
        .empty      (bid_empty),
        .busy       (), 
        .done       (bid_done),
        
        // Connect to HEAP wires (not RAM yet)
        .we         (heap_bid_we),
        .addr       (heap_bid_addr),
        .wdata      (heap_bid_wdata),
        .rdata      (bid_ram_rdata)
    );

    // --- BID BRAM MUX ---
    // If dumping, FSM controls addr. Write is disabled.
    wire [9:0]  bid_ram_addr  = dumping_active ? dump_addr : heap_bid_addr;
    wire        bid_ram_we    = dumping_active ? 1'b0      : heap_bid_we;
    wire [31:0] bid_ram_wdata = dumping_active ? 32'd0     : heap_bid_wdata;

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
        .HEAP_TYPE(`TYPE_ASK) 
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
        
        // Connect to HEAP wires
        .we         (heap_ask_we),
        .addr       (heap_ask_addr),
        .wdata      (heap_ask_wdata),
        .rdata      (ask_ram_rdata)
    );

    // --- ASK BRAM MUX ---
    wire [9:0]  ask_ram_addr  = dumping_active ? dump_addr : heap_ask_addr;
    wire        ask_ram_we    = dumping_active ? 1'b0      : heap_ask_we;
    wire [31:0] ask_ram_wdata = dumping_active ? 32'd0     : heap_ask_wdata;

    simple_bram u_ask_ram (
        .clk    (clk),
        .we     (ask_ram_we),
        .addr   (ask_ram_addr),
        .wdata  (ask_ram_wdata),
        .rdata  (ask_ram_rdata)
    );

    // =========================================================================
    // 4. DUMP LOGIC FSM
    // =========================================================================
    // This state machine hijacks the BRAMs to stream data out via UDP
    
    localparam S_IDLE       = 0;
    localparam S_WAIT_BUSY  = 1;
    localparam S_DUMP_BIDS  = 2;
    localparam S_DUMP_ASKS  = 3;
    localparam RAM_DEPTH    = 1024; // Assuming 10-bit address

    reg [2:0] state;
    reg       ram_read_valid; // Pipeline delay for BRAM read

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            dumping_active <= 0;
            dump_addr <= 0;
            dump_out_valid <= 0;
            dump_out_data <= 0;
            ram_read_valid <= 0;
        end else begin
            // Default
            dump_out_valid <= 0;
            ram_read_valid <= 0; // Default off unless in read loop

            case (state)
                S_IDLE: begin
                    dumping_active <= 0;
                    dump_addr <= 0;
                    if (start_dump) begin
                        state <= S_WAIT_BUSY;
                    end
                end

                S_WAIT_BUSY: begin
                    // Wait for any current trade to finish so BRAMs are stable
                    if (!internal_engine_busy) begin
                        dumping_active <= 1; // Seize control of BRAMs
                        state <= S_DUMP_BIDS;
                        dump_addr <= 0;
                    end
                end

                S_DUMP_BIDS: begin
                    // 1. Read Cycle: Address is set (dump_addr)
                    // 2. Data comes out next cycle (bid_ram_rdata)
                    
                    // Simple Pipelined Read
                    ram_read_valid <= 1; // Mark that next cycle has valid data
                    
                    // Capture Data from Previous Cycle
                    if (ram_read_valid) begin
                        // Filter: Only send non-zero entries (valid orders)
                        if (bid_ram_rdata != 32'd0) begin
                            dump_out_valid <= 1;
                            dump_out_data  <= bid_ram_rdata;
                        end
                    end

                    // Increment / Next State
                    if (dump_addr == RAM_DEPTH - 1) begin
                        dump_addr <= 0;
                        ram_read_valid <= 0; // Clear pipe for switch
                        state <= S_DUMP_ASKS;
                    end else begin
                        dump_addr <= dump_addr + 1;
                    end
                end

                S_DUMP_ASKS: begin
                    ram_read_valid <= 1;
                    
                    if (ram_read_valid) begin
                        if (ask_ram_rdata != 32'd0) begin
                            dump_out_valid <= 1;
                            dump_out_data  <= ask_ram_rdata;
                        end
                    end

                    if (dump_addr == RAM_DEPTH - 1) begin
                        dumping_active <= 0; // Release BRAMs
                        state <= S_IDLE;
                    end else begin
                        dump_addr <= dump_addr + 1;
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // 5. OUTPUT MUX & Debug
    // =========================================================================
    
    // If dumping, we output the Dump Stream. Otherwise, normal Trade Reports.
    assign trade_valid = dumping_active ? dump_out_valid : engine_out_valid;
    assign trade_info  = dumping_active ? dump_out_data  : engine_out_data;
    
    // Busy logic: We are busy if Engine is thinking OR if we are dumping
    assign engine_busy = internal_engine_busy || dumping_active;

    assign leds = {ask_full, bid_full, ask_empty, bid_empty};

endmodule