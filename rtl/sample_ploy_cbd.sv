`default_nettype none
`timescale 1ns / 1ps

module sample_ploy_cbd #(
    parameter int ETA = 2,                      // CBD parameter (typically 2 or 3 for Kyber/Dilithium)
    parameter int Q = 3329,                     // Modulus
    parameter int COEFF_WIDTH = 13,             // log2(Q) + 1
    parameter int N_COEFFS = 256,               // Number of coefficients
    parameter int SEED_BYTES = 64 * ETA         // Input byte array size (64η)
) (
    input   wire                            clk,
    input   wire                            rst,
    
    // Control signals
    input   wire                            start_i,
    output  logic                           done_o,
    output  logic                           busy_o,
    
    // Seed input (64η bytes)
    input   wire [SEED_BYTES-1:0][7:0]      seed_i,
    
    // Output coefficients
    output  logic [COEFF_WIDTH-1:0]         coeff_o,
    output  logic [7:0]                     coeff_idx_o,
    output  logic                           coeff_valid_o
);

    // ==========================================================
    // Constants and Local Parameters
    // ==========================================================
    localparam int BITS_TOTAL = SEED_BYTES * 8;  // Total bits from seed
    
    // ==========================================================
    // FSM States
    // ==========================================================
    typedef enum logic [1:0] {
        IDLE,
        CONVERT_BYTES,
        PROCESS_COEFFS,
        DONE
    } state_t;
    
    state_t state, next_state;
    
    // ==========================================================
    // Internal Registers and Wires
    // ==========================================================
    
    // Bit vector from BytesToBits conversion
    logic [BITS_TOTAL-1:0]      bit_vector;
    logic                       bits_valid;
    
    // Processing counters
    logic [7:0]                 i;              // Coefficient index (0 to 255)
    
    // Intermediate sums for x and y
    logic [COEFF_WIDTH-1:0]     x_sum;          // Sum for x
    logic [COEFF_WIDTH-1:0]     y_sum;          // Sum for y
    logic [COEFF_WIDTH-1:0]     f_i;            // f[i] = x - y mod q
    
    // Bit extraction indices
    logic [15:0]                bit_idx_x;      // Starting bit index for x
    logic [15:0]                bit_idx_y;      // Starting bit index for y
    
    // ==========================================================
    // BytesToBits Module Instantiation
    // ==========================================================
    bytes2bits #(
        .N_BYTES(SEED_BYTES)
    ) u_bytes2bits (
        .bytes_i(seed_i),
        .bits_o(bit_vector)
    );
    
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
                    next_state = CONVERT_BYTES;
                end
            end
            
            CONVERT_BYTES: begin
                // Conversion is combinational, proceed immediately
                next_state = PROCESS_COEFFS;
            end
            
            PROCESS_COEFFS: begin
                if (i >= N_COEFFS) begin
                    next_state = DONE;
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
            done_o          <= 1'b0;
            busy_o          <= 1'b0;
            
            // Coefficient outputs
            coeff_o         <= '0;
            coeff_idx_o     <= '0;
            coeff_valid_o   <= 1'b0;
            
            // Internal registers
            i               <= '0;
            x_sum           <= '0;
            y_sum           <= '0;
            f_i             <= '0;
            bits_valid      <= 1'b0;
            bit_idx_x       <= '0;
            bit_idx_y       <= '0;
            
        end else begin
            // Default: clear pulse signals
            coeff_valid_o <= 1'b0;
            
            case (state)
                IDLE: begin
                    if (start_i) begin
                        i           <= '0;
                        done_o      <= 1'b0;
                        busy_o      <= 1'b1;
                        bits_valid  <= 1'b0;
                    end
                end
                
                CONVERT_BYTES: begin
                    // Step 1: b ← BytesToBits(B)
                    // Conversion happens combinationally through u_bytes2bits
                    bits_valid <= 1'b1;
                end
                
                PROCESS_COEFFS: begin
                    if (i < N_COEFFS) begin
                        // Calculate bit indices
                        // Step 3: x ← Σ(j=0 to η-1) b[2iη + j]
                        // Step 4: y ← Σ(j=0 to η-1) b[2iη + η + j]
                        
                        bit_idx_x = (2 * i * ETA);           // Starting index for x
                        bit_idx_y = (2 * i * ETA) + ETA;     // Starting index for y
                        
                        // Calculate x_sum: sum of η bits starting at b[2iη]
                        x_sum = '0;
                        for (int j = 0; j < ETA; j++) begin
                            x_sum = x_sum + bit_vector[bit_idx_x + j];
                        end
                        
                        // Calculate y_sum: sum of η bits starting at b[2iη + η]
                        y_sum = '0;
                        for (int j = 0; j < ETA; j++) begin
                            y_sum = y_sum + bit_vector[bit_idx_y + j];
                        end
                        
                        // Step 5: f[i] ← x - y mod q
                        // Handle modular subtraction
                        if (x_sum >= y_sum) begin
                            f_i = x_sum - y_sum;
                        end else begin
                            // x < y, so (x - y) is negative, add q
                            f_i = Q - (y_sum - x_sum);
                        end
                        
                        // Output the coefficient
                        coeff_o       <= f_i;
                        coeff_idx_o   <= i[7:0];
                        coeff_valid_o <= 1'b1;
                        
                        // Increment coefficient index
                        i <= i + 1;
                        
                    end else begin
                        // All coefficients processed
                        busy_o <= 1'b0;
                    end
                end
                
                DONE: begin
                    done_o <= 1'b1;
                    busy_o <= 1'b0;
                end
                
            endcase
        end
    end

endmodule

`default_nettype wire