// --------------------------------------------------------------------
// UART Transmitter Module (TX)
// Implements 8-N-1 (8 Data Bits, No Parity, 1 Stop Bit)
// --------------------------------------------------------------------
module uart_transmitter (
    input wire         i_Clock,
    input wire         i_Tx_DV,     // Data Valid signal (single clock pulse to begin TX)
    input wire [7:0]   i_Tx_Byte,   // 8-bit byte to transmit (LSB first)
    output wire        o_Tx_Active, // High when transmission is in progress
    output reg         o_Tx_Serial, // Serial data output (connected to FPGA pin)
    output wire        o_Tx_Done    // High when transmission is complete (pulse)
    );
    
    // Registers (drive the 'output wire' ports)
    reg r_Tx_Active_i = 1'b0;
    reg r_Tx_Done_i   = 1'b0;

    // State machine definitions
    localparam s_IDLE         = 3'b000;
    localparam s_TX_START_BIT = 3'b001;
    localparam s_TX_DATA_BITS = 3'b010;
    localparam s_TX_STOP_BIT  = 3'b011;
    localparam s_CLEANUP      = 3'b100;
    
    // Registers
    reg [2:0]      r_SM_Main     = s_IDLE;
    reg [`CLOCK_COUNT_WIDTH-1:0] r_Clock_Count = 0; // Clock counter
    reg [2:0]      r_Bit_Index   = 0; // Index for 8 data bits
    reg [7:0]      r_Tx_Data     = 0; // Register to hold the byte being transmitted
    reg            r_Tx_Active   = 0;
    reg            r_Tx_Done     = 0; // Internal register to drive the output wire
    
    always @(posedge i_Clock)
    begin
        
        case (r_SM_Main)
            s_IDLE :
            begin
                o_Tx_Serial   <= 1'b1; // Default to High (Idle state)
                r_Tx_Done     <= 1'b0;
                r_Clock_Count <= 0;
                r_Bit_Index   <= 0;
                r_Tx_Active   <= 1'b0;
                
                if (i_Tx_DV == 1'b1)
                begin
                    r_Tx_Active <= 1'b1;
                    r_Tx_Data     <= i_Tx_Byte; // Latch data to be transmitted
                    r_SM_Main     <= s_TX_START_BIT;
                end
                else
                    r_SM_Main <= s_IDLE;
            end // case: s_IDLE
            
            
            // Send out Start Bit (Logic Low = 0)
            s_TX_START_BIT :
            begin
                o_Tx_Serial <= 1'b0; // Start bit is Low
                
                // Wait CLKS_PER_BIT clock cycles for start bit duration
                if (r_Clock_Count < `CLKS_PER_BIT - 1)
                begin
                    r_Clock_Count <= r_Clock_Count + 1;
                    r_SM_Main     <= s_TX_START_BIT;
                end
                else
                begin
                    r_Clock_Count <= 0;
                    r_SM_Main     <= s_TX_DATA_BITS; // Move to data bits
                end
            end // case: s_TX_START_BIT
            
            
            // Send out the 8 data bits (LSB first)
            s_TX_DATA_BITS :
            begin
                o_Tx_Serial <= r_Tx_Data[r_Bit_Index]; // Output current data bit
                
                // Wait CLKS_PER_BIT clock cycles for bit duration
                if (r_Clock_Count < `CLKS_PER_BIT - 1)
                begin
                    r_Clock_Count <= r_Clock_Count + 1;
                    r_SM_Main     <= s_TX_DATA_BITS;
                end
                else
                begin
                    r_Clock_Count <= 0;
                    
                    // Check if all 8 bits have been sent
                    if (r_Bit_Index < 7)
                    begin
                        r_Bit_Index <= r_Bit_Index + 1;
                        r_SM_Main   <= s_TX_DATA_BITS;
                    end
                    else
                    begin
                        r_Bit_Index <= 0;
                        r_SM_Main   <= s_TX_STOP_BIT; // Move to stop bit
                    end
                end
            end // case: s_TX_DATA_BITS
            
            
            // Send out Stop bit (Logic High = 1)
            s_TX_STOP_BIT :
            begin
                o_Tx_Serial <= 1'b1; // Stop bit is High (Idle state)
                
                // Wait CLKS_PER_BIT clock cycles for stop bit duration
                if (r_Clock_Count < `CLKS_PER_BIT - 1)
                begin
                    r_Clock_Count <= r_Clock_Count + 1;
                    r_SM_Main     <= s_TX_STOP_BIT;
                end
                else
                begin
                    r_Tx_Done     <= 1'b1; // Transmission complete pulse
                    r_Clock_Count <= 0;
                    r_SM_Main     <= s_IDLE;
                    r_Tx_Active   <= 1'b0;
                end
            end // case: s_Tx_STOP_BIT
            
            
            // Stay here 1 clock to confirm TX_DONE pulse
            s_CLEANUP :
            begin
                r_Tx_Done <= 1'b1; // Maintain pulse for one cycle
                r_SM_Main <= s_IDLE;
            end
            
            
            default :
                r_SM_Main <= s_IDLE;
                
        endcase
    end
    
    // Assign outputs (connecting the internal synchronous registers to the output wires)
    assign o_Tx_Active = r_Tx_Active;
    assign o_Tx_Done   = r_Tx_Done;
    
endmodule // transmitter