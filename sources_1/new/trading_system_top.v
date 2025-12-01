`timescale 1ns / 1ps
`default_nettype none

module trading_system_top (
    // Clocking
    input  wire        clk_udp,       // 125 MHz (Network Side)
    input  wire        rst_udp,
    input  wire        clk_engine,    // 200 MHz (Engine Side)
    input  wire        rst_engine,

    // UDP RX Stream (From MAC)
    input  wire [7:0]  rx_axis_tdata,
    input  wire        rx_axis_tvalid,
    input  wire        rx_axis_tlast,

    // UDP TX Interface (From Return FIFO to UDP TX Engine)
    output wire [7:0]  tx_fifo_tdata,
    output wire        tx_fifo_tvalid, // FIFO not empty
    input  wire        tx_fifo_tready, // UDP Engine Read Enable

     // Outputs from Order Book (for debugging/LEDs)
    output wire [31:0] trade_info,
    output wire        trade_valid,
    output wire        engine_busy,
    output wire [3:0]  leds,
    output wire [31:0] debug_ob_data,
    output wire        debug_input_fifo_empty,
    output wire        debug_input_fifo_full 
);

    // -------------------------------------------------------------------------
    // 1. EXTRACTOR (125 MHz) - Now with Trigger Logic
    // -------------------------------------------------------------------------
    wire [7:0] input_fifo_din;
    wire       input_fifo_wr_en;
    wire       input_fifo_full;
    wire       trigger_dump_raw;

    udp_payload_extractor extractor_inst (
        .clk(clk_udp),
        .rst(rst_udp),
        .s_axis_tdata(rx_axis_tdata),
        .s_axis_tvalid(rx_axis_tvalid),
        .s_axis_tlast(rx_axis_tlast),
        .fifo_din(input_fifo_din),
        .fifo_wr_en(input_fifo_wr_en),
        .fifo_full(input_fifo_full),
        .trigger_dump(trigger_dump_raw)
    );

    // Pulse Stretcher / Handshake for Trigger (125MHz -> 200MHz)
    // For simplicity, we assume the pulse is long enough or captured via 
    // a synchronizer in the Order Book. Ideally, use xpm_cdc_pulse.
    // Here we just pass it; ensure your Order Book synchronizes 'start_dump'!
    wire ob_start_dump = trigger_dump_raw; 

    // -------------------------------------------------------------------------
    // 2. INPUT FIFO (8-bit -> 32-bit, FWFT)
    // -------------------------------------------------------------------------
    wire [31:0] fifo_dout_raw;
    wire        fifo_empty;
    wire        fifo_rd_en;
    
    fifo_generator_0 input_fifo (
        .rst(rst_udp),
        .wr_clk(clk_udp),
        .din(input_fifo_din),
        .wr_en(input_fifo_wr_en),
        .full(input_fifo_full),
//        .wr_rst_busy(),
        
        .rd_clk(clk_engine),
        .dout(fifo_dout_raw),
        .rd_en(fifo_rd_en),
        .empty(fifo_empty)
        //.rd_rst_busy()
    );

    // -------------------------------------------------------------------------
    // 3. GLUE LOGIC (200 MHz)
    // -------------------------------------------------------------------------
    // Only read if we have data AND engine is ready
    assign fifo_rd_en = (!fifo_empty) && (!engine_busy);
    
    // NOP Filter: Only valid if data is non-zero
    wire [31:0] ob_input_data;
    // Endianness Swap (Big -> Little)
//    assign ob_input_data = {fifo_dout_raw[7:0], fifo_dout_raw[15:8], fifo_dout_raw[23:16], fifo_dout_raw[31:24]};
    assign ob_input_data = fifo_dout_raw;    
    wire ob_input_valid;
    assign ob_input_valid = fifo_rd_en && (ob_input_data != 32'd0);
    assign debug_ob_data  = ob_input_data;

    // -------------------------------------------------------------------------
    // 4. ORDER BOOK ENGINE (200 MHz)
    // -------------------------------------------------------------------------
//    wire [31:0] trade_info;
//    wire        trade_valid;

    order_book_top ob_inst (
        .clk(clk_engine),
        .rst_n(!rst_engine),
        
        // Input
        .input_valid(ob_input_valid),
        .input_data(ob_input_data),
        .start_dump(ob_start_dump), // <--- CONNECT THIS to your Engine's Dump Trigger
        
        // Flow Control
        .engine_busy(engine_busy),
        
        // Output (Trades AND Dump Data go here)
        .trade_valid(trade_valid),
        .trade_info(trade_info),
        .leds(leds)
    );

    // -------------------------------------------------------------------------
    // 5. RETURN FIFO (32-bit -> 8-bit, FWFT) - NEW!
    // -------------------------------------------------------------------------
    // This captures Trades/Dumps and sends them back to the network.
    
    fifo_generator_1 return_fifo (
        .rst(rst_engine),
        
        // WRITE SIDE (Engine 200 MHz)
        .wr_clk(clk_engine),
        .din(trade_info),     // We assume Little Endian from Engine
        .wr_en(trade_valid),  // Write whenever engine outputs data
        .full(),              // If full, we lose data (add 'full' check to engine if critical)
        
        // READ SIDE (Network 125 MHz)
        .rd_clk(clk_udp),
        .dout(tx_fifo_tdata),
        .rd_en(tx_fifo_tready),
        .empty(tx_fifo_empty)
    );
    
    wire tx_fifo_empty;
    assign tx_fifo_tvalid = !tx_fifo_empty; // FWFT Logic
    
    assign debug_input_fifo_empty = fifo_empty;
    assign debug_input_fifo_full  = input_fifo_full;


endmodule