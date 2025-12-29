// Converts an array of bytes into a flat bit vector (little-endian within each byte).
module bytes2bits #(
	parameter int N_BYTES = 1  // number of input bytes; output width is 8*N_BYTES
)(
	input  wire  logic [N_BYTES-1:0][7:0] bytes_i,
	output logic [N_BYTES*8-1:0] bits_o
);

	integer i;

	always_comb begin
		bits_o = '0;
		for (i = 0; i < N_BYTES; i++) begin
			bits_o[i*8 +: 8] = bytes_i[i];
		end
	end

endmodule