`timescale 1ns / 1ps
`default_nettype none

// -----------------------------------------------------------------------------
// pulse_cdc: Pulse Synchronizer (Asynchronous Pulse CDC) - FIX APPLIED
// -----------------------------------------------------------------------------
module pulse_cdc #(
    parameter DEST_D_WIDTH = 1
) (
    input  wire         src_clk,
    input  wire         src_rst,
    input  wire         src_in,          
    
    input  wire         dest_clk,
    input  wire         dest_rst,
    output wire [DEST_D_WIDTH-1:0] dest_out // Now driven by assign
);

    localparam SYNC_STAGES = 3; 

    reg [DEST_D_WIDTH-1:0] src_reg;
    reg [DEST_D_WIDTH-1:0] sync_regs [0:SYNC_STAGES-1];
    reg [DEST_D_WIDTH-1:0] dest_pulse_reg;
    reg [DEST_D_WIDTH-1:0] dest_out_reg; // New internal register for procedural assignment
    
    // --- Source Domain Register (Toggling Generator) ---
    always @(posedge src_clk) begin
        if (src_rst) begin
            src_reg <= 'b0;
        end else if (src_in) begin
            src_reg <= ~src_reg; 
        end
    end

    // --- Destination Domain Synchronization and Edge Detection ---
    always @(posedge dest_clk) begin
        if (dest_rst) begin
            sync_regs[0] <= 'b0;
            sync_regs[1] <= 'b0;
            sync_regs[2] <= 'b0;
            dest_pulse_reg <= 'b0;
            dest_out_reg <= 'b0; // Use internal reg
        end else begin
            sync_regs[0] <= src_reg;
            sync_regs[1] <= sync_regs[0];
            sync_regs[2] <= sync_regs[1]; 
            
            if (sync_regs[2] != dest_pulse_reg) begin
                dest_pulse_reg <= sync_regs[2];
                dest_out_reg <= 1'b1; // Procedural assignment to internal reg
            end else begin
                dest_out_reg <= 1'b0;
            end
        end
    end
    
    // Continuous assignment from internal reg to external port
    assign dest_out = dest_out_reg;

endmodule

// -----------------------------------------------------------------------------
// sync_data: Simple Data Synchronizer 
// -----------------------------------------------------------------------------
module sync_data #(
    parameter WIDTH = 1 // Data width
) (
    input  wire         src_clk,
    input  wire         src_rst,
    input  wire [WIDTH-1:0] src_in, 
    
    input  wire         dest_clk,
    input  wire         dest_rst,
    output wire [WIDTH-1:0] dest_out
);

    localparam SYNC_STAGES = 2; 

    reg [WIDTH-1:0] sync_regs [0:SYNC_STAGES-1];

    always @(posedge dest_clk) begin
        if (dest_rst) begin
            sync_regs[0] <= 'b0;
            sync_regs[1] <= 'b0;
        end else begin
            sync_regs[0] <= src_in;
            sync_regs[1] <= sync_regs[0];
        end
    end
    
    assign dest_out = sync_regs[1];

endmodule

// -----------------------------------------------------------------------------
// uart_request_detector: Finds the F0 E0 D0 sequence.
// -----------------------------------------------------------------------------
module uart_request_detector (
    input  wire        clk,
    input  wire        rst,
    
    input  wire        rx_byte_valid,
    input  wire [7:0]  rx_byte_data,
    
    output reg         uart_start_dump_raw
);

    localparam OP_DUMP_B0 = 8'hF0; 
    localparam OP_DUMP_B1 = 8'hE0; 
    localparam OP_DUMP_B2 = 8'hD0; 
    
    localparam S_IDLE    = 2'd0;
    localparam S_OP1     = 2'd1; 
    localparam S_OP2     = 2'd2; 
    localparam S_OP_DONE = 2'd3; 

    reg [1:0] state;

    always @(posedge clk) begin
        uart_start_dump_raw <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
        end else if (rx_byte_valid) begin
            
            case (state)
                S_IDLE: begin
                    if (rx_byte_data == OP_DUMP_B0) state <= S_OP1;
                    else state <= S_IDLE;
                end

                S_OP1: begin
                    if (rx_byte_data == OP_DUMP_B1) state <= S_OP2;
                    else if (rx_byte_data == OP_DUMP_B0) state <= S_OP1; 
                    else state <= S_IDLE;
                end

                S_OP2: begin
                    if (rx_byte_data == OP_DUMP_B2) begin
                        uart_start_dump_raw <= 1'b1; 
                        state <= S_OP_DONE;
                    end
                    else if (rx_byte_data == OP_DUMP_B0) state <= S_OP1; 
                    else state <= S_IDLE;
                end
                
                S_OP_DONE: begin
                    state <= S_IDLE;
                end
                
            endcase
        end
    end
endmodule

// -----------------------------------------------------------------------------
// uart_tx_handler: Manages the handshake for sending data out the UART PHY.
// -----------------------------------------------------------------------------
/*
* uart_tx_handler: Manages the handshake for sending data out the UART PHY.
* FIXES:
* 1. Properly handles AXI Stream handshake using s_axis_tvalid/s_axis_tready.
* 2. Incorporates s_axis_tlast (which signals the Sentinel) to cleanly terminate the stream.
*/
module uart_tx_handler (
    input  wire        clk,
    input  wire        rst,
    
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    input  wire         s_axis_tlast, // NEW: Used to terminate the UART stream
    output wire        s_axis_tready, 
    
    input  wire        tx_byte_ready, 
    output wire [7:0]  tx_byte_data, 
    output reg         tx_byte_valid  
);

    localparam S_IDLE = 1'b0;
    localparam S_SEND = 1'b1;

    reg state = S_IDLE;
    reg [7:0] tx_data_reg = 8'h00; 

    // Ready is asserted only when the UART PHY is ready to receive a new byte
    // OR if we are waiting for the last TLAST pulse to clear the pipe.
    assign s_axis_tready = tx_byte_ready & (state == S_IDLE);

    always @(posedge clk) begin
        tx_byte_valid <= 1'b0;
        
        if (rst) begin
            state <= S_IDLE;
            tx_data_reg <= 8'h00;
        end else begin
            case (state)
                S_IDLE: begin
                    if (s_axis_tvalid) begin
                        // If we are ready to take data, grab it.
                        if (tx_byte_ready) begin
                            tx_data_reg <= s_axis_tdata;
                            state <= S_SEND;
                        end
                        // Note: s_axis_tready covers the condition tx_byte_ready & (state == S_IDLE).
                        // If s_axis_tvalid is true and s_axis_tready is true (due to tx_byte_ready), 
                        // the previous block handles the capture and transition.
                    end
                end
                
                S_SEND: begin
                    // This byte is loaded and ready to be sent to the PHY.
                    if (tx_byte_ready) begin
                        tx_byte_valid <= 1'b1;
                        if (s_axis_tlast) begin
                            // The sentinel byte (which asserts tlast) is now consumed and sent. We are done.
                            state <= S_IDLE;
                        end else if (s_axis_tvalid) begin
                            // If the next byte is already waiting, grab it immediately 
                            // and loop back to the send state in the same cycle.
                            tx_data_reg <= s_axis_tdata;
                            state <= S_SEND; // Stay in SEND, ready for next transfer
                        end else begin
                            // No data waiting. Go to IDLE to wait for the next packet word.
                            state <= S_IDLE;
                        end
                    end 
                    // else: tx_byte_ready is low, so wait one more cycle for the PHY.
                end
            endcase
        end
    end

    // The data output is always the currently latched byte
    assign tx_byte_data = tx_data_reg;

endmodule

// -----------------------------------------------------------------------------
// uart_phy: Functional 8N1 Asynchronous Serial Communications Interface
// Clock: 125 MHz. Baud: 115200. (CLK_PER_BIT = 1085 cycles)
// -----------------------------------------------------------------------------
module uart_phy #(
    parameter CLK_FREQ  = 125_000_000, 
    parameter BAUD_RATE = 115200       
) (
    input  wire        clk,
    input  wire        rst,
    
    // Physical Interface
    input  wire        uart_rx,
    output wire        uart_tx,
    
    // RX Parallel Interface (to fpga_top -> Detector)
    output reg         rx_byte_valid,
    output reg  [7:0]  rx_byte_data,
    
    // TX Parallel Interface (from fpga_top -> Handler)
    input  wire [7:0]  tx_byte_data,
    input  wire        tx_byte_valid,  
    output reg         tx_byte_ready   
);
        
    // Constants calculated for 125MHz / 115200 baud
    localparam CLK_PER_BIT      = 1085; // 125,000,000 / 115,200 ~= 1085.06
    localparam CLK_HALF_BIT     = (CLK_PER_BIT / 2);
    localparam COUNTER_WIDTH    = 11; // Enough for 1085 
    
    // --- TX Logic ---
    localparam TX_IDLE  = 2'd0;
    localparam TX_DATA  = 2'd2;
    localparam TX_STOP  = 2'd3;
    
    reg [1:0] tx_state = TX_IDLE;
    reg [3:0] tx_bit_cnt = 0;
    reg [7:0] tx_buffer = 0;
    reg [COUNTER_WIDTH-1:0] tx_clk_cnt = 0;
    reg tx_data_out = 1'b1; 

    assign uart_tx = tx_data_out;
    
    always @(posedge clk) begin
        if (rst) begin
            tx_state <= TX_IDLE;
            tx_clk_cnt <= 0;
            tx_bit_cnt <= 0;
            tx_byte_ready <= 1'b1;
            tx_data_out <= 1'b1;
        end else begin
            tx_byte_ready <= (tx_state == TX_IDLE); 

            tx_clk_cnt <= tx_clk_cnt + 1;
            
            if (tx_clk_cnt == CLK_PER_BIT - 1) begin
                tx_clk_cnt <= 0;

                case (tx_state)
                    TX_IDLE: begin
                        if (tx_byte_valid) begin
                            tx_buffer <= tx_byte_data;
                            tx_data_out <= 1'b0; // Start bit
                            tx_state <= TX_DATA; 
                            tx_bit_cnt <= 0; 
                        end
                    end
                    
                    TX_DATA: begin
                        tx_data_out <= tx_buffer[tx_bit_cnt]; 

                        if (tx_bit_cnt == 7) begin
                            tx_state <= TX_STOP;
                        end else begin
                            tx_bit_cnt <= tx_bit_cnt + 1;
                        end
                    end
                    
                    TX_STOP: begin
                        tx_data_out <= 1'b1; // Stop bit
                        tx_state <= TX_IDLE;
                    end
                endcase
            end
        end
    end

    // --- RX Logic ---
    localparam RX_IDLE      = 2'd0;
    localparam RX_WAIT_VALID = 2'd1;
    localparam RX_SAMPLING  = 2'd2;
    localparam RX_STOP_WAIT = 2'd3;

    reg [1:0] rx_state = RX_IDLE;
    reg [3:0] rx_bit_cnt = 0;
    reg [COUNTER_WIDTH-1:0] rx_clk_cnt_div = 0;
    reg [7:0] rx_buffer = 0;
    
    localparam RX_START_OFFSET = CLK_HALF_BIT - 1;
    
    always @(posedge clk) begin
        rx_byte_valid <= 1'b0;
        
        if (rst) begin
            rx_state <= RX_IDLE;
            rx_clk_cnt_div <= 0;
            rx_bit_cnt <= 0;
        end else begin

            case (rx_state)
                RX_IDLE: begin
                    rx_clk_cnt_div <= 0;
                    if (uart_rx == 1'b0) begin
                        rx_state <= RX_WAIT_VALID;
                    end
                end
                
                RX_WAIT_VALID: begin
                    // Counts to center of START bit.
                    if (rx_clk_cnt_div == RX_START_OFFSET) begin
                        if (uart_rx == 1'b0) begin
                            // Start bit confirmed. The counter is now aligned to 0.5 bit time.
                            // Keep counting to the full bit time for the next sample.
                            rx_clk_cnt_div <= 0;
                            rx_bit_cnt <= 0;
                            rx_state <= RX_SAMPLING;
                        end else begin
                            // Glitch, back to idle
                            rx_state <= RX_IDLE;
                        end
                    end else begin
                        rx_clk_cnt_div <= rx_clk_cnt_div + 1;
                    end
                end
                
                RX_SAMPLING: begin
                    if (rx_clk_cnt_div == CLK_PER_BIT - 1) begin
                        rx_clk_cnt_div <= 0;
                        
                        // Sample Data Bit at the end of the previous bit window
                        rx_buffer[rx_bit_cnt] <= uart_rx; 
                        
                        if (rx_bit_cnt == 7) begin
                            rx_state <= RX_STOP_WAIT;
                        end else begin
                            rx_bit_cnt <= rx_bit_cnt + 1;
                        end
                    end else begin
                        rx_clk_cnt_div <= rx_clk_cnt_div + 1;
                    end
                end

                RX_STOP_WAIT: begin
                    rx_clk_cnt_div <= rx_clk_cnt_div + 1;
                    
                    if (rx_clk_cnt_div == CLK_PER_BIT - 1) begin
                        rx_clk_cnt_div <= 0;

                        if (uart_rx == 1'b1) begin
                            rx_byte_data <= rx_buffer;
                            rx_byte_valid <= 1'b1;
                        end
                        
                        rx_state <= RX_IDLE; 
                    end
                end
            endcase
        end
    end
    
endmodule