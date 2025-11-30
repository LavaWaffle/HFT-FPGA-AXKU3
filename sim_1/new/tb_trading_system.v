`timescale 1ns / 1ps

module tb_trading_system;

    // -------------------------------------------------------------------------
    // 1. Signal Declarations
    // -------------------------------------------------------------------------
    // UDP Domain (125 MHz)
    reg        clk_udp = 0;
    reg        rst_udp = 1;
    reg [7:0]  rx_axis_tdata = 0;
    reg        rx_axis_tvalid = 0;
    reg        rx_axis_tlast = 0;

    // Engine Domain (200 MHz)
    reg        clk_engine = 0;
    reg        rst_engine = 1;
    
    // Outputs
    wire [31:0] trade_info;
    wire        trade_valid;
    wire        engine_busy;
    wire [3:0]  leds;

    // -------------------------------------------------------------------------
    // 2. Instantiate the Wrapper (UUT)
    // -------------------------------------------------------------------------
    trading_system_top uut (
        .clk_udp(clk_udp),
        .rst_udp(rst_udp),
        .clk_engine(clk_engine),
        .rst_engine(rst_engine),
        .rx_axis_tdata(rx_axis_tdata),
        .rx_axis_tvalid(rx_axis_tvalid),
        .rx_axis_tlast(rx_axis_tlast),
        .trade_info(trade_info),
        .trade_valid(trade_valid),
        .engine_busy(engine_busy),
        .leds(leds)
    );

    // -------------------------------------------------------------------------
    // 3. Clock Generation
    // -------------------------------------------------------------------------
    always #4.0 clk_udp    = ~clk_udp;    // 125 MHz (Period 8ns)
    always #2.5 clk_engine = ~clk_engine; // 200 MHz (Period 5ns)

    // -------------------------------------------------------------------------
    // 4. Helper Tasks
    // -------------------------------------------------------------------------
    
    // Send a single byte
    task send_byte(input [7:0] data);
        begin
            @(posedge clk_udp);
            rx_axis_tvalid <= 1;
            rx_axis_tdata  <= data;
            rx_axis_tlast  <= 0;
        end
    endtask

    // Send a complete packet (Header + Payload)
    task send_packet(input [31:0] order_data);
        integer i;
        begin
            // 1. Send 42 Bytes of Header Garbage (MAC/IP/UDP headers)
            // The Sniffer module ignores these.
            for (i=0; i<42; i=i+1) begin
                send_byte(8'hAA); 
            end

            // 2. Send the 32-bit Order Payload (4 Bytes)
            // WE SEND BIG ENDIAN (Network Order): Byte 3 (MSB) -> Byte 0 (LSB)
            // Target: Price=1 (0x0001), Flags=High, Qty=1
            // Let's send the bytes MSB first as Python struct.pack('!I') would.
            send_byte(order_data[31:24]); // Byte 3
            send_byte(order_data[23:16]); // Byte 2
            send_byte(order_data[15:8]);  // Byte 1
            
            // Last Byte needs TLAST
            @(posedge clk_udp);
            rx_axis_tdata  <= order_data[7:0]; // Byte 0
            rx_axis_tlast  <= 1;
            
            @(posedge clk_udp);
            rx_axis_tvalid <= 0;
            rx_axis_tlast  <= 0;
            rx_axis_tdata  <= 0;
            
            // Gap between packets
            repeat(20) @(posedge clk_udp); 
        end
    endtask

    // -------------------------------------------------------------------------
    // 5. Main Test Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("--- Starting Trading System Simulation ---");
        
        // Reset Pulse
        #100;
        rst_udp = 0;
        rst_engine = 0; // Active High reset in this TB context, flipped in wrapper
        #100;

        // TEST CASE 1: Simple Order
        // Price: 1 (0x0001)
        // Is_Buy: 1
        // Is_Bot: 0
        // Qty: 1 (0x0001)
        // Binary: 0000 0000 0000 0001 | 1 | 0 | 00 0000 0000 0001
        // Hex:    0    0    0    1      8     0    0    1
        // Packet: 32'h00018001
        $display("[TB] Sending Order: Price=1, Buy, Qty=1 (Raw: 0x00018001)");
        send_packet(32'h00018001);

        // TEST CASE 2: High Price Order (Endian check)
        // Price: 255 (0x00FF)
        // Is_Buy: 0
        // Is_Bot: 0
        // Qty: 10 (0x000A)
        // Packet: 32'h00FF000A
        $display("[TB] Sending Order: Price=255, Sell, Qty=10 (Raw: 0x00FF000A)");
        send_packet(32'h00FF000A);

        #2000;
        $display("--- Simulation Complete ---");
        $finish;
    end

endmodule

// -------------------------------------------------------------------------
// DUMMY ORDER BOOK (Mocks your real engine for testing)
// -------------------------------------------------------------------------
//module order_book_top (
//    input wire clk,
//    input wire rst_n,
//    input wire input_valid,
//    input wire [31:0] input_data,
//    output reg engine_busy,
//    output reg trade_valid,
//    output reg [31:0] trade_info,
//    output reg [3:0] leds
//);
//    // Break out fields for easy reading
//    wire [15:0] price  = input_data[31:16];
//    wire        is_buy = input_data[15];
//    wire [13:0] qty    = input_data[13:0];

//    always @(posedge clk) begin
//        if (!rst_n) begin
//            engine_busy <= 0;
//            trade_valid <= 0;
//        end else begin
//            // Default
//            trade_valid <= 0;

//            if (input_valid) begin
//                $display("\n[ORDER BOOK] Received Data!");
//                $display("    Raw Hex: %h", input_data);
//                $display("    Price:   %0d", price);
//                $display("    Type:    %s", is_buy ? "BUY" : "SELL");
//                $display("    Qty:     %0d", qty);
                
//                // Endianness Check
//                if (price > 10000 && price != 65535) 
//                    $display("    [WARNING] Price is huge (%0d). Endianness swap might be wrong!", price);
//                else 
//                    $display("    [SUCCESS] Values look sane.");
//            end
//        end
//    end
//endmodule