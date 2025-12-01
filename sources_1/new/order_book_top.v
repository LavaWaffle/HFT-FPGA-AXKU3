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
    wire [1:0]  bid_cmd;
    wire [31:0] bid_data_to_heap;
    wire [31:0] bid_root;
    wire        bid_empty, bid_full, bid_done;
    wire [9:0]  bid_count; // [NEW] Connected for optimization
    
    wire        heap_bid_we;
    wire [9:0]  heap_bid_addr;
    wire [31:0] heap_bid_wdata;
    wire [31:0] bid_ram_rdata; 

    // --- Ask Side Wire Intercepts ---
    wire [1:0]  ask_cmd;
    wire [31:0] ask_data_to_heap;
    wire [31:0] ask_root;
    wire        ask_empty, ask_full, ask_done;
    wire [9:0]  ask_count; // [NEW] Connected for optimization

    wire        heap_ask_we;
    wire [9:0]  heap_ask_addr;
    wire [31:0] heap_ask_wdata;
    wire [31:0] ask_ram_rdata; 

    matching_engine u_engine (
        .clk            (clk),
        .rst_n          (rst_n),
        .input_valid    (input_valid && !dumping_active), 
        .input_data     (input_data),
        .engine_busy    (internal_engine_busy),
        .bid_root       (bid_root),
        .bid_empty      (bid_empty),
        .bid_done       (bid_done),
        .bid_cmd        (bid_cmd),
        .bid_data_out   (bid_data_to_heap),
        .ask_root       (ask_root),
        .ask_empty      (ask_empty),
        .ask_done       (ask_done),
        .ask_cmd        (ask_cmd),
        .ask_data_out   (ask_data_to_heap),
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
        .count      (bid_count), // [FIX] Wiring this up
        .full       (bid_full),
        .empty      (bid_empty),
        .busy       (), 
        .done       (bid_done),
        .we         (heap_bid_we),
        .addr       (heap_bid_addr),
        .wdata      (heap_bid_wdata),
        .rdata      (bid_ram_rdata)
    );

    // --- BID BRAM MUX ---
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
        .count      (ask_count), // [FIX] Wiring this up
        .full       (ask_full),
        .empty      (ask_empty),
        .busy       (),
        .done       (ask_done),
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
    // 4. DUMP LOGIC FSM (Optimized)
    // =========================================================================
    // Scans only valid items (1 to Count). Skips 0 to 1024 scan.
    
    localparam S_IDLE        = 0;
    localparam S_WAIT_BUSY   = 1;
    localparam S_DUMP_BIDS   = 2;
    localparam S_FLUSH_BIDS  = 3; // Catch the last Bid item
    localparam S_DUMP_ASKS   = 4;
    localparam S_FLUSH_ASKS  = 5; // Catch the last Ask item
    localparam S_FINISH_DUMP = 6;

    reg [2:0] state;
    reg       ram_read_valid; 

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
            ram_read_valid <= 0; 

            case (state)
                S_IDLE: begin
                    dumping_active <= 0;
                    dump_addr <= 0;
                    if (start_dump) begin
                        state <= S_WAIT_BUSY;
                    end
                end

                S_WAIT_BUSY: begin
                    if (!internal_engine_busy) begin
                        dumping_active <= 1; 
                        
                        // Optimization: If Bids exist, start dumping. Else check Asks.
                        if (bid_count > 0) begin
                            dump_addr <= 1; // Heap starts at 1
                            state <= S_DUMP_BIDS;
                        end else if (ask_count > 0) begin
                            dump_addr <= 1;
                            state <= S_DUMP_ASKS;
                        end else begin
                            // Both empty
                            dumping_active <= 0;
                            state <= S_IDLE;
                        end
                    end
                end

                S_DUMP_BIDS: begin
                    ram_read_valid <= 1; // Pipeline active
                    
                    // Output Data from PREVIOUS cycle
                    if (ram_read_valid && bid_ram_rdata != 32'd0) begin
                        dump_out_valid <= 1;
                        dump_out_data  <= bid_ram_rdata;
                    end

                    // Address Logic
                    if (dump_addr == bid_count) begin
                        // We just requested the last item.
                        // It will arrive next cycle. Go to Flush.
                        state <= S_FLUSH_BIDS;
                    end else begin
                        dump_addr <= dump_addr + 1;
                    end
                end
                
                S_FLUSH_BIDS: begin
                    // Capture the final item from the pipeline
                    if (bid_ram_rdata != 32'd0) begin
                        dump_out_valid <= 1;
                        dump_out_data  <= bid_ram_rdata;
                    end
                    
                    // Transition to Asks
                    if (ask_count > 0) begin
                        dump_addr <= 1;
                        state <= S_DUMP_ASKS;
                    end else begin
//                        dumping_active <= 0;
                        state <= S_FINISH_DUMP;
                    end
                end

                S_DUMP_ASKS: begin
                    ram_read_valid <= 1;
                    
                    if (ram_read_valid && ask_ram_rdata != 32'd0) begin
                        dump_out_valid <= 1;
                        dump_out_data  <= ask_ram_rdata;
                    end

                    if (dump_addr == ask_count) begin
                        state <= S_FLUSH_ASKS;
                    end else begin
                        dump_addr <= dump_addr + 1;
                    end
                end
                
                S_FLUSH_ASKS: begin
                    if (ask_ram_rdata != 32'd0) begin
                        dump_out_valid <= 1;
                        dump_out_data  <= ask_ram_rdata;
                    end
                    
//                    dumping_active <= 0;
                    state <= S_FINISH_DUMP;
                end
                
                S_FINISH_DUMP: begin
                     dumping_active <= 0; // Now it is safe to switch the Mux
                     state <= S_IDLE;
                end
            endcase
        end
    end

    // Output Mux
    assign trade_valid = dumping_active ? dump_out_valid : engine_out_valid;
    assign trade_info  = dumping_active ? dump_out_data  : engine_out_data;
    assign engine_busy = internal_engine_busy || dumping_active;

    assign leds = {ask_full, bid_full, ask_empty, bid_empty};

endmodule