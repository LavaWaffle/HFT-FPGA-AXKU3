`include "order_defines.v"

module matching_engine (
    input wire clk,
    input wire rst_n,

    // --- Input from UDP/Strategy ---
    input wire input_valid,
    input wire [31:0] input_data, 
    output reg engine_busy,

    // --- Interface to Bid Heap (Max Heap) ---
    input wire [31:0] bid_root,    
    input wire bid_empty,
    input wire bid_done,           
    output reg [1:0] bid_cmd,
    output reg [31:0] bid_data_out,

    // --- Interface to Ask Heap (Min Heap) ---
    input wire [31:0] ask_root,    
    input wire ask_empty,
    input wire ask_done,
    output reg [1:0] ask_cmd,
    output reg [31:0] ask_data_out,

    // --- Trade Reporting ---
    output reg trade_valid,
    output reg [31:0] trade_info  
);

    // Internal State
    reg [3:0] state;
    localparam IDLE         = 0;
    localparam CHECK_MATCH  = 1; 
    localparam EXEC_POP     = 2; 
    localparam EXEC_UPDATE  = 3; 
    localparam WAIT_HEAP    = 4; 
    localparam PLACE_ORDER  = 5; 
    localparam WAIT_PUSH    = 6; 
    localparam DONE         = 7;

    // Registers
    reg [15:0] my_price;
    reg [14:0] my_qty;
    reg my_is_buy;
    reg my_id;

    // Helper logic
    reg [31:0] opp_root;
    reg [15:0] opp_price;
    reg [14:0] opp_qty;
    reg opp_empty;

    reg [31:0] my_book_root;
    reg        my_book_empty;
    reg [15:0] my_book_root_price;
    reg [14:0] my_book_root_qty;

    // --------------------------------------------------------
    // [FIX] INTERMEDIATE MATH WIRES
    // Verilog forbids `(a - b)[13:0]`. We must compute it here.
    // --------------------------------------------------------
    wire [14:0] calc_diff;
    wire [14:0] calc_sum;

    assign calc_diff = opp_qty - my_qty;       // Used in EXEC_UPDATE
    assign calc_sum  = my_book_root_qty + my_qty; // Used in PLACE_ORDER (Merge)

    // --------------------------------------------------------
    // Mux Logic
    // --------------------------------------------------------
    always @(*) begin
        // 1. Select Opposite Book
        if (my_is_buy) begin
            opp_root  = ask_root;
            opp_empty = ask_empty;
        end else begin
            opp_root  = bid_root;
            opp_empty = bid_empty;
        end
        opp_price = `PRICE(opp_root);
        opp_qty   = `QTY(opp_root);

        // 2. Select My Book
        if (my_is_buy) begin
            my_book_root  = bid_root;
            my_book_empty = bid_empty;
        end else begin
            my_book_root  = ask_root;
            my_book_empty = ask_empty;
        end
        my_book_root_price = `PRICE(my_book_root);
        my_book_root_qty   = `QTY(my_book_root);
    end

    // --------------------------------------------------------
    // Main FSM
    // --------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            engine_busy <= 0;
            bid_cmd <= `CMD_NOP;
            ask_cmd <= `CMD_NOP;
            trade_valid <= 0;
        end else begin
            case (state)
                IDLE: begin
                    trade_valid <= 0;
                    bid_cmd <= `CMD_NOP;
                    ask_cmd <= `CMD_NOP;
                    
                    if (input_valid) begin
                        engine_busy <= 1;
                        my_price  <= `PRICE(input_data);
                        my_is_buy <= `IS_BUY(input_data); 
                        my_id     <= `IS_BOT(input_data);
                        my_qty    <= `QTY(input_data);
                        state <= CHECK_MATCH;
                    end else begin
                        engine_busy <= 0;
                    end
                end

                CHECK_MATCH: begin
                    if (opp_empty) begin
                        state <= PLACE_ORDER;
                    end
                    else if ((my_is_buy && my_price >= opp_price) || 
                             (!my_is_buy && my_price <= opp_price)) begin
                        
                        if (my_qty >= opp_qty) state <= EXEC_POP;
                        else                   state <= EXEC_UPDATE;
                        
                    end else begin
                        state <= PLACE_ORDER;
                    end
                end

                EXEC_POP: begin
                    if (my_is_buy) ask_cmd <= `CMD_POP;
                    else           bid_cmd <= `CMD_POP;

                    trade_valid <= 1;
                    trade_info  <= {opp_price, 1'b0, opp_qty[13:0]}; // Truncate qty to safe 14 bits

                    my_qty <= my_qty - opp_qty;
                    state <= WAIT_HEAP;
                end

                EXEC_UPDATE: begin
                    // [FIX] Use calc_diff wire instead of inline math
                    if (my_is_buy) begin
                        ask_cmd <= `CMD_UPDATE;
                        // Updating ASK book -> Side = 0
                        ask_data_out <= {opp_price, 1'b0, `IS_BOT(opp_root), calc_diff[13:0]};
                    end else begin
                        bid_cmd <= `CMD_UPDATE;
                        // Updating BID book -> Side = 1
                        bid_data_out <= {opp_price, 1'b1, `IS_BOT(opp_root), calc_diff[13:0]};
                    end

                    trade_valid <= 1;
                    trade_info  <= {opp_price, 1'b0, my_qty[13:0]};

                    my_qty <= 0; 
                    state <= WAIT_HEAP;
                end

                WAIT_HEAP: begin
                    trade_valid <= 0;
                    bid_cmd <= `CMD_NOP;
                    ask_cmd <= `CMD_NOP;

                    if (my_is_buy) begin
                        if (ask_done) begin
                            if (my_qty > 0) state <= CHECK_MATCH;
                            else            state <= DONE;
                        end
                    end else begin
                        if (bid_done) begin
                            if (my_qty > 0) state <= CHECK_MATCH;
                            else            state <= DONE;
                        end
                    end
                end

                PLACE_ORDER: begin
                    if (my_qty > 0) begin
                        // OPTIMIZATION: Merge at Root
                        if (!my_book_empty && (my_price == my_book_root_price)) begin
                             // [FIX] Use calc_sum wire instead of inline math
                             if (my_is_buy) begin
                                bid_cmd <= `CMD_UPDATE;
                                // BID -> Side 1
                                bid_data_out <= {my_price, 1'b1, my_id, calc_sum[13:0]};
                            end else begin
                                ask_cmd <= `CMD_UPDATE;
                                // ASK -> Side 0
                                ask_data_out <= {my_price, 1'b0, my_id, calc_sum[13:0]};
                            end
                            state <= WAIT_PUSH; 

                        end else begin
                            // STANDARD PUSH
                            if (my_is_buy) begin
                                bid_cmd <= `CMD_PUSH;
                                // BID -> Side 1
                                bid_data_out <= {my_price, 1'b1, my_id, my_qty[13:0]};
                            end else begin
                                ask_cmd <= `CMD_PUSH;
                                // ASK -> Side 0
                                ask_data_out <= {my_price, 1'b0, my_id, my_qty[13:0]};
                            end
                            state <= WAIT_PUSH;
                        end
                    end else begin
                        state <= DONE;
                    end
                end
                
                WAIT_PUSH: begin
                     bid_cmd <= `CMD_NOP;
                     ask_cmd <= `CMD_NOP;
                     if (my_is_buy) begin
                        if (bid_done) state <= DONE;
                     end else begin
                        if (ask_done) state <= DONE;
                     end
                end

                DONE: begin
                    engine_busy <= 0;
                    state <= IDLE;
                end

            endcase
        end
    end

endmodule