`timescale 1ns / 1ps
`default_nettype none

// This module handles the slow transmission rate and relies entirely on the
// FIFO's 'tx_valid_in' (empty signal) to determine the packet boundary.
module uart_tx_channel (
    input  wire        clk,
    input  wire        rst,
    
    // ------------------------------------
    // Input Stream Interface (From 32->8 bit FIFO)
    // ------------------------------------
    input  wire [7:0]  tx_data_in,
    input  wire        tx_valid_in,  // Data available (!empty)
    output reg         tx_ready_out, // Read enable (rd_en)
    
    // ------------------------------------
    // Physical Output Pin
    // ------------------------------------
    output wire        fpga_uart_tx
);

    // --- INTERNAL WIRES for Transmitter Core Instantiation ---
    wire       tx_dv_pulse;
    wire       tx_active;
    wire       tx_done_pulse;

    // --- NEW: FOOTER CONFIGURATION (4-Byte Sentinel/Footer) ---
    // Change from 8'h18 to 32'h00000000 for a 4-byte zero footer
    localparam [31:0]  TX_FOOTER_WORD = 32'hFFFFFFFF; 

    // --- STATE MACHINE PARAMETERS (200 MHz Clock) ---
    localparam S_IDLE        = 2'b00; // Waiting for first byte of packet
    localparam S_SEND_DATA   = 2'b01; // Sending data bytes and managing rate mismatch
    localparam S_SEND_FOOTER = 2'b10; // Sending the 4-byte footer (looped state)

    reg [1:0]  state = S_IDLE;
    
    // --- NEW: FOOTER INDEX ---
    // Tracks which byte of the 4-byte footer we are currently sending (0 to 3)
    reg [1:0] r_Footer_Index = 2'b00; 

    // --- TX DATA HOLD REGISTER ---
    reg [7:0]  tx_data_reg = 8'h00; 
    
    // --- OUTPUT REGISTERS ---
    reg        tx_dv_i = 1'b0;

    // --- LOGIC: Track if we're in the initial transient phase where Tx_Done hasn't pulsed yet ---
    reg        first_byte_sending = 1'b0;


    // --- COMBINATIONAL: Select current byte of the footer ---
    // Note: Assumes Big Endian transmission (Byte 3 -> Byte 0)
    wire [7:0] tx_footer_byte;
//    assign tx_footer_byte = TX_FOOTER_WORD[31 - (r_Footer_Index * 8) : 24 - (r_Footer_Index * 8)];
    assign tx_footer_byte = TX_FOOTER_WORD >> (r_Footer_Index * 8);

    // --- STATE MACHINE LOGIC ---
    always @(posedge clk) begin
        if (rst) begin
            state              <= S_IDLE;
            tx_ready_out       <= 1'b0;
            tx_dv_i            <= 1'b0;
            first_byte_sending <= 1'b0;
            r_Footer_Index     <= 2'b00;
        end else begin
            
            // --- Defaults ---
            tx_dv_i      <= 1'b0;
            tx_ready_out <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (tx_valid_in) begin
                        // Packet Start: Latch the first byte and begin transmission
                        tx_data_reg        <= tx_data_in; 
                        tx_dv_i            <= 1'b1; // Start the slow transmission
                        first_byte_sending <= 1'b1;
                        tx_ready_out       <= 1'b1; // Pulse read enable for the first byte
                        state              <= S_SEND_DATA;
                    end
                end
                
                S_SEND_DATA: begin
                    
                    if (first_byte_sending) begin
                        first_byte_sending <= 1'b0;
                    
                    end else if (tx_done_pulse) begin
                        // Previous byte is done. Check FIFO for more data.
                        if (tx_valid_in) begin
                            // FIFO still has data. Read next byte and continue.
                            tx_data_reg  <= tx_data_in; 
                            tx_dv_i      <= 1'b1;    // Pulse TX_DV
                            tx_ready_out <= 1'b1;    // Pulse read enable for one cycle
                        end else begin
                            // FIFO Empty. Initiate 4-byte footer sequence.
                            r_Footer_Index <= 2'b00; // Start at the first byte (index 0)
                            tx_data_reg  <= tx_footer_byte; // Latch Byte 0
                            tx_dv_i      <= 1'b1;    // Start transmission of Byte 0
                            state        <= S_SEND_FOOTER;
                        end
                    end
                end

                S_SEND_FOOTER: begin
                    // Loop state to send remaining 4 bytes of footer
                    if (tx_done_pulse) begin
                        
                        if (r_Footer_Index < 2'b11) begin // Check if index is 0, 1, or 2 (less than 3)
                            // Send the next byte
                            r_Footer_Index <= r_Footer_Index + 1; // Move to next index
                            tx_data_reg  <= tx_footer_byte;    // Latch new byte (uses updated r_Footer_Index next cycle)
                            tx_dv_i      <= 1'b1;            // Pulse TX_DV
                        end else begin
                            // All 4 bytes sent (index 3 finished)
                            state <= S_IDLE; 
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
    
    // --- Transmitter Core Instantiation (from uart_core.v) ---
    uart_transmitter transmitter_inst (
        .i_Clock     (clk),
        .i_Tx_DV     (tx_dv_i),        // Start TX pulse from our controller
        .i_Tx_Byte   (tx_data_reg),    // The byte we latched
        .o_Tx_Active (tx_active),
        .o_Tx_Serial (fpga_uart_tx),   // Connect directly to the physical pin
        .o_Tx_Done   (tx_done_pulse)   // Pulse indicating 8-N-1 sequence completed
    );
    
endmodule // uart_tx_channel