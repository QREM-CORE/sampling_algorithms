`default_nettype none
`timescale 1ns / 1ps

module sample_ntt #(
    parameter int Q = 3329,              // Modulus for Dilithium/Kyber
    parameter int COEFF_WIDTH = 13,      // log2(Q) + 1
    parameter int SEED_BYTES = 32,       // 32-byte seed input
    parameter int OUTPUT_SIZE = 256      // 256 coefficients
) (
    input   wire                            clk,
    input   wire                            rst,
    
    // Control signals
    input   wire                            start_i,
    output  logic                           done_o,
    
    // Seed input (32 bytes)
    input   wire [SEED_BYTES*8-1:0]         seed_i,
    input   wire [15:0]                     nonce_i,        // Two indices combined
    
    // XOF Interface (to Keccak Core)
    output  logic [127:0]                   xof_data_o,     // Data to absorb
    output  logic                           xof_valid_o,
    output  logic                           xof_last_o,
    output  logic [15:0]                    xof_keep_o,
    input   wire                            xof_ready_i,
    
    input   wire [127:0]                    xof_squeeze_data_i,
    input   wire                            xof_squeeze_valid_i,
    input   wire                            xof_squeeze_last_i,
    output  logic                           xof_squeeze_ready_o,
    output  logic                           xof_stop_o,     // Stop squeezing
    
    // Output coefficients
    output  logic [COEFF_WIDTH-1:0]         coeff_o,
    output  logic [7:0]                     coeff_idx_o,
    output  logic                           coeff_valid_o
);

    // FSM States
    typedef enum logic [2:0] {
        IDLE,
        ABSORB_SEED,
        WAIT_SQUEEZE,
        PROCESS_BYTES,
        DONE
    } state_t;
    
    state_t state, next_state;
    
    // Internal registers
    logic [7:0]                 j;              // Output coefficient counter
    logic [23:0]                squeeze_buffer; // Buffer for 3 bytes from XOF
    logic [1:0]                 byte_cnt;       // Count bytes in buffer (0-2)
    logic                       buffer_valid;
    
    logic [COEFF_WIDTH-1:0]     d1, d2;         // Two candidates per 3 bytes
    logic                       seed_absorbed;
    
    // XOF absorption counter
    logic [5:0]                 absorb_cnt;     // Count absorbed bytes (34 total)
    
    // Constants
    localparam int TOTAL_ABSORB_BYTES = SEED_BYTES + 2; // 32 + 2 = 34 bytes
    
    // ==========================================================
    // FSM: State Register
    // ==========================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
    end
    
    // ==========================================================
    // FSM: Next State Logic
    // ==========================================================
    always_comb begin
        next_state = state;
        
        case (state)
            IDLE: begin
                if (start_i) begin
                    next_state = ABSORB_SEED;
                end
            end
            
            ABSORB_SEED: begin
                if (seed_absorbed && xof_ready_i) begin
                    next_state = WAIT_SQUEEZE;
                end
            end
            
            WAIT_SQUEEZE: begin
                if (xof_squeeze_valid_i) begin
                    next_state = PROCESS_BYTES;
                end
            end
            
            PROCESS_BYTES: begin
                if (j >= OUTPUT_SIZE) begin
                    next_state = DONE;
                end else if (!buffer_valid && xof_squeeze_valid_i) begin
                    next_state = PROCESS_BYTES;
                end else if (!buffer_valid && !xof_squeeze_valid_i) begin
                    next_state = WAIT_SQUEEZE;
                end
            end
            
            DONE: begin
                next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // ==========================================================
    // FSM: Output Logic & Datapath
    // ==========================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            // Control outputs
            done_o              <= 1'b0;
            xof_valid_o         <= 1'b0;
            xof_last_o          <= 1'b0;
            xof_data_o          <= '0;
            xof_keep_o          <= '0;
            xof_squeeze_ready_o <= 1'b0;
            xof_stop_o          <= 1'b0;
            
            // Coefficient outputs
            coeff_o             <= '0;
            coeff_idx_o         <= '0;
            coeff_valid_o       <= 1'b0;
            
            // Internal registers
            j                   <= '0;
            squeeze_buffer      <= '0;
            byte_cnt            <= '0;
            buffer_valid        <= 1'b0;
            seed_absorbed       <= 1'b0;
            absorb_cnt          <= '0;
            d1                  <= '0;
            d2                  <= '0;
            
        end else begin
            // Default: clear pulse signals
            coeff_valid_o <= 1'b0;
            
            case (state)
                IDLE: begin
                    if (start_i) begin
                        j               <= '0;
                        absorb_cnt      <= '0;
                        seed_absorbed   <= 1'b0;
                        buffer_valid    <= 1'b0;
                        byte_cnt        <= '0;
                        done_o          <= 1'b0;
                        xof_stop_o      <= 1'b0;
                    end
                end
                
                ABSORB_SEED: begin
                    // Absorb seed || nonce (34 bytes total)
                    xof_valid_o <= 1'b1;
                    
                    if (xof_ready_i) begin
                        if (absorb_cnt == 0) begin
                            // First beat: first 16 bytes of seed
                            xof_data_o <= seed_i[255:128];
                            xof_keep_o <= 16'hFFFF;
                            xof_last_o <= 1'b0;
                            absorb_cnt <= absorb_cnt + 16;
                            
                        end else if (absorb_cnt == 16) begin
                            // Second beat: next 16 bytes of seed
                            xof_data_o <= seed_i[127:0];
                            xof_keep_o <= 16'hFFFF;
                            xof_last_o <= 1'b0;
                            absorb_cnt <= absorb_cnt + 16;
                            
                        end else if (absorb_cnt == 32) begin
                            // Third beat: 2-byte nonce (indices)
                            xof_data_o <= {112'b0, nonce_i};
                            xof_keep_o <= 16'h0003; // Only first 2 bytes valid
                            xof_last_o <= 1'b1;     // Last transfer
                            seed_absorbed <= 1'b1;
                            xof_valid_o <= 1'b0;
                        end
                    end
                end
                
                WAIT_SQUEEZE: begin
                    xof_squeeze_ready_o <= 1'b1;
                end
                
                PROCESS_BYTES: begin
                    xof_squeeze_ready_o <= !buffer_valid; // Ready when buffer empty
                    
                    // Load new 3-byte buffer from XOF
                    if (!buffer_valid && xof_squeeze_valid_i && xof_squeeze_ready_o) begin
                        squeeze_buffer <= xof_squeeze_data_i[23:0];
                        buffer_valid   <= 1'b1;
                        byte_cnt       <= 2'd3;
                    end
                    
                    // Process buffered bytes (Algorithm steps 6-14)
                    if (buffer_valid && byte_cnt == 2'd3) begin
                        // Step 6: d1 = C[0] + 256*(C[1] mod 16)
                        d1 <= {squeeze_buffer[11:8], squeeze_buffer[7:0]} & 13'h0FFF;
                        
                        // Step 7: d2 = ⌊C[1]/16⌋ + 16*C[2]
                        d2 <= {squeeze_buffer[23:16], squeeze_buffer[11:8]};
                        
                        byte_cnt <= 2'd2; // Mark as partially processed
                    end
                    
                    // Step 8-11: Check d1 < Q
                    if (buffer_valid && byte_cnt == 2'd2) begin
                        if (d1 < Q && j < OUTPUT_SIZE) begin
                            coeff_o       <= d1;
                            coeff_idx_o   <= j[7:0];
                            coeff_valid_o <= 1'b1;
                            j             <= j + 1;
                        end
                        byte_cnt <= 2'd1;
                    end
                    
                    // Step 12-15: Check d2 < Q
                    if (buffer_valid && byte_cnt == 2'd1) begin
                        if (d2 < Q && j < OUTPUT_SIZE) begin
                            coeff_o       <= d2;
                            coeff_idx_o   <= j[7:0];
                            coeff_valid_o <= 1'b1;
                            j             <= j + 1;
                        end
                        buffer_valid <= 1'b0;
                        byte_cnt     <= 2'd0;
                    end
                    
                    // Check completion
                    if (j >= OUTPUT_SIZE) begin
                        xof_stop_o          <= 1'b1;
                        xof_squeeze_ready_o <= 1'b0;
                    end
                end
                
                DONE: begin
                    done_o     <= 1'b1;
                    xof_stop_o <= 1'b1;
                end
                
            endcase
        end
    end

endmodule

`default_nettype wire