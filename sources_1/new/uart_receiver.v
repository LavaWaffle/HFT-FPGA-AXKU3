`timescale 1ns / 1ps

// ====================================================================
// UART PARAMETERS
// IMPORTANT: You MUST set the correct clock divider value below.
// CLKS_PER_BIT = (i_Clock Frequency) / (Target Baud Rate)
// Example: 200 MHz clock, 115200 baud -> 200,000,000 / 115200 = 1736
// ====================================================================
`define CLKS_PER_BIT 1736 // Set for 200 MHz Clock @ 115200 Baud

// Calculate the minimum required bit width for the counter
// log2(1736) is ~10.76. We need 11 bits (index 0 to 10) to count up to 2047.
`define CLOCK_COUNT_WIDTH 11
// --------------------------------------------------------------------
// UART Receiver Module (RX)
// Implements 8-N-1 (8 Data Bits, No Parity, 1 Stop Bit)
// --------------------------------------------------------------------
module uart_receiver (
    input wire        i_Clock,
    input wire        i_Rx_Serial, // Asynchronous serial data input
    output wire       o_Rx_DV,     // Data Valid pulse (one clock cycle wide)
    output wire [7:0] o_Rx_Byte    // Received 8-bit byte (LSB first)
    );

    // State machine definitions
    localparam s_IDLE         = 3'b000;
    localparam s_RX_START_BIT = 3'b001;
    localparam s_RX_DATA_BITS = 3'b010;
    localparam s_RX_STOP_BIT  = 3'b011;
    localparam s_CLEANUP      = 3'b100;

    // Registers for clock domain crossing and data capture
    reg            r_Rx_Data_R = 1'b1; // Double-register for metastability protection
    reg            r_Rx_Data   = 1'b1;
    
    // State machine, counter, and data registers
    reg [`CLOCK_COUNT_WIDTH-1:0] r_Clock_Count = 0; // Clock counter for timing 1 bit period
    reg [2:0]      r_Bit_Index = 0; // Index for the 8 data bits (0 to 7)
    reg [7:0]      r_Rx_Byte   = 0;
    reg [2:0]      r_SM_Main   = s_IDLE;
    reg            r_Rx_DV     = 0;

    // Purpose: Double-register the incoming data (i_Rx_Serial) to mitigate metastability
    // as the asynchronous signal crosses into the synchronous i_Clock domain.
    always @(posedge i_Clock)
    begin
        r_Rx_Data_R <= i_Rx_Serial;
        r_Rx_Data   <= r_Rx_Data_R;
    end
    
    // Purpose: Control RX state machine
    always @(posedge i_Clock)
    begin
        r_Rx_DV <= 1'b0; // Default to not valid
        
        case (r_SM_Main)
            s_IDLE :
            begin
                r_Clock_Count <= 0;
                r_Bit_Index   <= 0;
                
                // Start bit detected (Rx line goes low)
                if (r_Rx_Data == 1'b0)
                    r_SM_Main <= s_RX_START_BIT;
                else
                    r_SM_Main <= s_IDLE;
            end
            
            // Check middle of start bit for validity and jump to data sampling
            s_RX_START_BIT :
            begin
                if (r_Clock_Count == (`CLKS_PER_BIT - 1) / 2) // Check at 1/2 bit time
                begin
                    if (r_Rx_Data == 1'b0) // Still low, valid start bit
                    begin
                        r_Clock_Count <= 0; // Reset counter for full bit timing
                        r_SM_Main     <= s_RX_DATA_BITS;
                    end
                    else // Glitch or false start, return to idle
                        r_SM_Main <= s_IDLE;
                end
                else
                begin
                    r_Clock_Count <= r_Clock_Count + 1;
                    r_SM_Main     <= s_RX_START_BIT;
                end
            end
            
            // Sample the 8 data bits (LSB first)
            s_RX_DATA_BITS :
            begin
                // Wait CLKS_PER_BIT-1 clock cycles to sample serial data (middle of bit)
                if (r_Clock_Count < `CLKS_PER_BIT - 1)
                begin
                    r_Clock_Count <= r_Clock_Count + 1;
                    r_SM_Main     <= s_RX_DATA_BITS;
                end
                else
                begin
                    r_Clock_Count <= 0;
                    r_Rx_Byte[r_Bit_Index] <= r_Rx_Data; // Sample and store data bit (LSB first)
                    
                    // Check if all 8 bits have been received
                    if (r_Bit_Index < 7)
                    begin
                        r_Bit_Index <= r_Bit_Index + 1;
                        r_SM_Main   <= s_RX_DATA_BITS;
                    end
                    else
                    begin
                        r_Bit_Index <= 0;
                        r_SM_Main   <= s_RX_STOP_BIT; // Move to stop bit phase
                    end
                end
            end
            
            // Receive Stop bit (must be logic high)
            s_RX_STOP_BIT :
            begin
                // Wait CLKS_PER_BIT-1 clock cycles for Stop bit to finish
                if (r_Clock_Count < `CLKS_PER_BIT - 1)
                begin
                    r_Clock_Count <= r_Clock_Count + 1;
                    r_SM_Main     <= s_RX_STOP_BIT;
                end
                else
                begin
                    r_Rx_DV       <= 1'b1; // Data is ready (one clock pulse)
                    r_Clock_Count <= 0;
                    r_SM_Main     <= s_CLEANUP;
                end
            end
            
            // Stay here for 1 clock cycle to hold o_Rx_DV high
            s_CLEANUP :
            begin
                r_SM_Main <= s_IDLE;
                r_Rx_DV   <= 1'b0; // Already reset at start of cycle, but good practice
            end
            
            default :
                r_SM_Main <= s_IDLE;
                
        endcase
    end
    
    // Assign outputs
    assign o_Rx_DV   = r_Rx_DV;
    assign o_Rx_Byte = r_Rx_Byte;
    
endmodule // receiver