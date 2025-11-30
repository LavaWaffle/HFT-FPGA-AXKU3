`timescale 1ns / 1ps
`default_nettype none

module trading_system_top (
    // Clocking
    input  wire        clk_udp,       // 125 MHz (Write Side)
    input  wire        rst_udp,
    input  wire        clk_engine,    // 200 MHz (Read Side)
    input  wire        rst_engine,

    // UDP RX Stream (Snooped from MAC)
    input  wire [7:0]  rx_axis_tdata,
    input  wire        rx_axis_tvalid,
    input  wire        rx_axis_tlast,

    // Outputs from Order Book (for debugging/LEDs)
    output wire [31:0] trade_info,
    output wire        trade_valid,
    output wire        engine_busy,
    output wire [3:0]  leds,
    
    // --- ADD THESE DEBUG PORTS ---
    output wire [31:0] debug_ob_data,   // See exactly what the engine sees
    output wire        debug_fifo_empty,// Is the FIFO working?
    output wire        debug_fifo_full  // Did we overflow?
);

    // -------------------------------------------------------------------------
    // 1. EXTRACT PAYLOAD (125 MHz)
    // -------------------------------------------------------------------------
    wire [7:0] fifo_din;
    wire       fifo_wr_en;
    wire       fifo_full;

    udp_payload_extractor extractor_inst (
        .clk(clk_udp),
        .rst(rst_udp),
        .s_axis_tdata(rx_axis_tdata),
        .s_axis_tvalid(rx_axis_tvalid),
        .s_axis_tlast(rx_axis_tlast),
        .fifo_din(fifo_din),
        .fifo_wr_en(fifo_wr_en),
        .fifo_full(fifo_full)
    );

    // -------------------------------------------------------------------------
    // 2. ASYNC FIFO (8-bit -> 32-bit, FWFT)
    // -------------------------------------------------------------------------
    wire [31:0] fifo_dout_raw;
    wire        fifo_empty;
    wire        fifo_rd_en;
    
    // NOTE: Even though the IP is VHDL, Vivado handles Verilog instantiation automatically
    fifo_generator_0 my_fifo (
        .rst(rst_udp),          // Reset (Use the slower clock reset usually, or a sys_reset)
        
        // WRITE DOMAIN (125 MHz)
        .wr_clk(clk_udp),
        .din(fifo_din),
        .wr_en(fifo_wr_en),
        .full(fifo_full),
        .wr_rst_busy(),         // Ignored
        
        // READ DOMAIN (200 MHz)
        .rd_clk(clk_engine),
        .dout(fifo_dout_raw),
        .rd_en(fifo_rd_en),
        .empty(fifo_empty),
        .rd_rst_busy()          // Ignored
    );

    // -------------------------------------------------------------------------
    // 3. GLUE LOGIC & ENDIANNESS SWAP (200 MHz)
    // -------------------------------------------------------------------------
    
    // Logic: Pull from FIFO only if we have data AND engine is listening
    // FWFT Mode: Data is valid immediately when !empty
    assign fifo_rd_en = (!fifo_empty) && (!engine_busy);
    
    wire ob_input_valid;
//    assign ob_input_valid = fifo_rd_en; // Pulse valid when we read
    assign ob_input_valid = fifo_rd_en && (ob_input_data != 32'd0);

    // Endianness Swap
    // Network is Big Endian (Byte 0 first). FIFO output packs Byte 0 into LSB or MSB.
    // Usually, we need to swap to align with 32-bit integers in the FPGA.
    // If your prices look crazy (e.g. 16 million instead of 1), swap these wires.
    wire [31:0] ob_input_data;
    
    // Option A: Standard Swap (Big Endian Network -> Little Endian FPGA)
//    assign ob_input_data = {fifo_dout_raw[7:0], fifo_dout_raw[15:8], fifo_dout_raw[23:16], fifo_dout_raw[31:24]};
    
    // Option B: Passthrough (Use this if Option A makes data garbage)
     assign ob_input_data = fifo_dout_raw;

    // -------------------------------------------------------------------------
    // 4. ORDER BOOK ENGINE (200 MHz)
    // -------------------------------------------------------------------------
    
    order_book_top ob_inst (
        .clk(clk_engine),
        .rst_n(!rst_engine),       // Order book uses Active Low reset
        .input_valid(ob_input_valid),
        .input_data(ob_input_data),
        .engine_busy(engine_busy),
        .trade_valid(trade_valid),
        .trade_info(trade_info),
        .leds(leds)
    );
    
    assign debug_ob_data    = ob_input_data; // The swapped 32-bit data
    assign debug_fifo_empty = fifo_empty;
    assign debug_fifo_full  = fifo_full;

endmodule