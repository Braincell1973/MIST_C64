//
// mist_io.v
//
// mist_io for the MiST board
// http://code.google.com/p/mist-board/
//
// Copyright (c) 2014 Till Harbaum <till@harbaum.org>
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
///////////////////////////////////////////////////////////////////////

//
// Use buffer to access SD card. It's time-critical part.
// Made module synchroneous with 2 clock domains: clk_sys and SPI_SCK
//                                                           (Sorgelig)
//
// for synchronous projects default value for PS2DIV is fine for any frequency of system clock.
// clk_ps2 = clk_sys/(PS2DIV*2)
//

module mist_io #(parameter STRLEN=0, parameter PS2DIV=100)
(

	// parameter STRLEN and the actual length of conf_str have to match
	input [(8*STRLEN)-1:0] conf_str,

	// Global clock. It should be around 100MHz (higher is better).
	input             clk_sys,

	// Global SPI clock from ARM. 24MHz
	input             SPI_SCK,

	input             CONF_DATA0,
	input             SPI_SS2,
	output            SPI_DO,
	input             SPI_DI,

	output reg  [7:0] joystick_0,
	output reg  [7:0] joystick_1,
	output reg [15:0] joystick_analog_0,
	output reg [15:0] joystick_analog_1,
	output      [1:0] buttons,
	output      [1:0] switches,
	output            scandoubler_disable,
	output            ypbpr,

	output reg [31:0] status,

	// SD config
	input             sd_conf,
	input             sd_sdhc,
	output            img_mounted, 				// signaling that new image has been mounted
	output reg [31:0] img_size,    				// size of image in bytes

	// SD block level access
	input      [31:0] sd_lba,
	input             sd_rd,
	input             sd_wr,
	output reg        sd_ack,
	output reg        sd_ack_conf,

	// SD byte level access. Signals for 2-PORT altsyncram.
	output reg  [8:0] sd_buff_addr,
	output reg  [7:0] sd_buff_dout,
	input       [7:0] sd_buff_din,
	output reg        sd_buff_wr,

	// ps2 keyboard emulation
	output            ps2_kbd_clk,
	output reg        ps2_kbd_data,
	output            ps2_mouse_clk,
	output reg        ps2_mouse_data,
	input             ps2_caps_led,

	// ARM -> FPGA download
	input             ioctl_force_erase,
	output reg        ioctl_download = 0, 		// signal indicating an active download
	output reg        ioctl_erasing = 0,  		// signal indicating an active erase
	output reg  [7:0] ioctl_index,        		// menu index used to upload the file
	output reg        ioctl_wr = 0,
	output reg [24:0] ioctl_addr,
	output reg  [7:0] ioctl_dout,
	output reg			ioctl_download_active,	//flag to start download after load address aquired lca 
   output reg [15:0] ioctl_load_address,		// loading address for PRG & T64 files
	
	input 				reset_n,						// MAIN RESET SIGNAL
	
	//CARTRIDGE SIGNALS - LCA
	input 				cart_detach_key,			// CTRL-D from keyboard
	output reg [15:0] cart_id ,					// cart ID or cart type
	output reg [15:0] cart_loadaddr ,			// 1st bank loading address	
	output reg [15:0] cart_bank_size ,			// length of each bank
	output reg [31:0] cart_packet_length ,		// chip packet length (header & data)
	output reg [7:0] cart_exrom ,					// CRT file EXROM status
	output reg [7:0] cart_game ,					// CRT file GAME status
	output reg cart_attached = 0	,				// FLAG to say cart has been loaded
	output reg  cartridge_reset = 0					// Cartridge reset flag once cart has been loaded
);


reg [7:0] b_data;
reg [6:0] sbuf;
reg [7:0] cmd;
reg [2:0] bit_cnt;    // counts bits 0-7 0-7 ...
reg [9:0] byte_cnt;   // counts bytes
reg [7:0] but_sw;
reg [2:0] stick_idx;

reg    mount_strobe = 0;

reg [2:0] cart_reset = 'b00; 							// cartridge reset after load state machine

assign img_mounted  = mount_strobe;

assign buttons = but_sw[1:0];
assign switches = but_sw[3:2];
assign scandoubler_disable = but_sw[4];
assign ypbpr = but_sw[5];

wire [7:0] spi_dout = { sbuf, SPI_DI};

// this variant of user_io is for 8 bit cores (type == a4) only
wire [7:0] core_type = 8'ha4;

// command byte read by the io controller
wire [7:0] sd_cmd = { 4'h5, sd_conf, sd_sdhc, sd_wr, sd_rd };

reg spi_do;
assign SPI_DO = CONF_DATA0 ? 1'bZ : spi_do;

wire [7:0] kbd_led = { 2'b01, 4'b0000, ps2_caps_led, 1'b1};

// drive MISO only when transmitting core id
always@(negedge SPI_SCK) begin
	if(!CONF_DATA0) begin
		// first byte returned is always core type, further bytes are 
		// command dependent
      if(byte_cnt == 0) begin
		  spi_do <= core_type[~bit_cnt];

		end else begin
			case(cmd)
				// reading config string
				8'h14: begin
					// returning a byte from string
						if(byte_cnt < STRLEN + 1) spi_do <= conf_str[{STRLEN - byte_cnt,~bit_cnt}];
							else spi_do <= 0;
					end

				// reading sd card status
				8'h16: begin
						if(byte_cnt == 1) spi_do <= sd_cmd[~bit_cnt];
						else if((byte_cnt >= 2) && (byte_cnt < 6)) spi_do <= sd_lba[{5-byte_cnt, ~bit_cnt}];
						else spi_do <= 0;
					end

				// reading sd card write data
				8'h18:
						spi_do <= b_data[~bit_cnt];

				// reading keyboard LED status
				8'h1f:
						spi_do <= kbd_led[~bit_cnt];

				default:
						spi_do <= 0;
			endcase
		end
   end
end

reg b_wr2,b_wr3;
always @(negedge clk_sys) begin
	b_wr3      <= b_wr2;
	sd_buff_wr <= b_wr3;
end

// SPI receiver
always@(posedge SPI_SCK or posedge CONF_DATA0) begin

	if(CONF_DATA0) begin
		b_wr2 <= 0;
	   bit_cnt <= 0;
	   byte_cnt <= 0;
		sd_ack <= 0;
		sd_ack_conf <= 0;
	end else begin
		b_wr2 <= 0;

		sbuf <= spi_dout[6:0];
		bit_cnt <= bit_cnt + 1'd1;
		if(bit_cnt == 5) begin
			if (byte_cnt == 0) sd_buff_addr <= 0;
			if((byte_cnt != 0) & (sd_buff_addr != 511)) sd_buff_addr <= sd_buff_addr + 1'b1;
			if((byte_cnt == 1) & ((cmd == 8'h17) | (cmd == 8'h19))) sd_buff_addr <= 0;
		end

		// finished reading command byte
      if(bit_cnt == 7) begin
			if(~&byte_cnt) byte_cnt <= byte_cnt + 8'd1;
			if(byte_cnt == 0) begin
				cmd <= spi_dout;

				if(spi_dout == 8'h19) begin
					sd_ack_conf  <= 1;
					sd_buff_addr <= 0;
				end
				if((spi_dout == 8'h17) || (spi_dout == 8'h18)) begin
					sd_ack       <= 1;
					sd_buff_addr <= 0;
				end
				if(spi_dout == 8'h18) b_data <= sd_buff_din;

				mount_strobe <= 0;

			end else begin
			
				case(cmd)
					// buttons and switches
					8'h01: but_sw <= spi_dout; 
					8'h02: joystick_0 <= spi_dout;
					8'h03: joystick_1 <= spi_dout;

					// store incoming ps2 mouse bytes 
					8'h04: begin
							ps2_mouse_fifo[ps2_mouse_wptr] <= spi_dout; 
							ps2_mouse_wptr <= ps2_mouse_wptr + 1'd1;
						end

					// store incoming ps2 keyboard bytes 
					8'h05: begin
							ps2_kbd_fifo[ps2_kbd_wptr] <= spi_dout; 
							ps2_kbd_wptr <= ps2_kbd_wptr + 1'd1;
						end
				
					8'h15: status[7:0] <= spi_dout;
				
					// send SD config IO -> FPGA
					// flag that download begins
					// sd card knows data is config if sd_dout_strobe is asserted
					// with sd_ack still being inactive (low)
					8'h19,
					// send sector IO -> FPGA
					// flag that download begins
					8'h17: begin
							sd_buff_dout <= spi_dout;
							b_wr2 <= 1;
						end

					8'h18: b_data <= sd_buff_din;

					// joystick analog
					8'h1a: begin
							// first byte is joystick index
							if(byte_cnt == 1) stick_idx <= spi_dout[2:0];
							else if(byte_cnt == 2) begin
								// second byte is x axis
								if(stick_idx == 0) joystick_analog_0[15:8] <= spi_dout;
									else if(stick_idx == 1) joystick_analog_1[15:8] <= spi_dout;
							end else if(byte_cnt == 3) begin
								// third byte is y axis
								if(stick_idx == 0) joystick_analog_0[7:0] <= spi_dout;
									else if(stick_idx == 1) joystick_analog_1[7:0] <= spi_dout;
							end
						end

					// notify image selection
					8'h1c: mount_strobe <= 1;

					// send image info
					8'h1d: if(byte_cnt<5) img_size[(byte_cnt-1)<<3 +:8] <= spi_dout;

					// status, 32bit version
					8'h1e: if(byte_cnt<5) status[(byte_cnt-1)<<3 +:8] <= spi_dout;
					default: ;
				endcase
			end
		end
	end
end


///////////////////////////////   PS2   ///////////////////////////////
// 8 byte fifos to store ps2 bytes
localparam PS2_FIFO_BITS = 3;

reg clk_ps2;
always @(negedge clk_sys) begin
	integer cnt;
	cnt <= cnt + 1'd1;
	if(cnt == PS2DIV) begin
		clk_ps2 <= ~clk_ps2;
		cnt <= 0;
	end
end

// keyboard
reg [7:0] ps2_kbd_fifo[1<<PS2_FIFO_BITS];
reg [PS2_FIFO_BITS-1:0] ps2_kbd_wptr;
reg [PS2_FIFO_BITS-1:0] ps2_kbd_rptr;

// ps2 transmitter state machine
reg [3:0] ps2_kbd_tx_state;
reg [7:0] ps2_kbd_tx_byte;
reg ps2_kbd_parity;

assign ps2_kbd_clk = clk_ps2 || (ps2_kbd_tx_state == 0);

// ps2 transmitter
// Takes a byte from the FIFO and sends it in a ps2 compliant serial format.
reg ps2_kbd_r_inc;
always@(posedge clk_sys) begin
	reg old_clk;
	old_clk <= clk_ps2;
	if(~old_clk & clk_ps2) begin
		ps2_kbd_r_inc <= 0;

		if(ps2_kbd_r_inc) ps2_kbd_rptr <= ps2_kbd_rptr + 1'd1;

		// transmitter is idle?
		if(ps2_kbd_tx_state == 0) begin
			// data in fifo present?
			if(ps2_kbd_wptr != ps2_kbd_rptr) begin
				// load tx register from fifo
				ps2_kbd_tx_byte <= ps2_kbd_fifo[ps2_kbd_rptr];
				ps2_kbd_r_inc <= 1;

				// reset parity
				ps2_kbd_parity <= 1;

				// start transmitter
				ps2_kbd_tx_state <= 1;

				// put start bit on data line
				ps2_kbd_data <= 0;			// start bit is 0
			end
		end else begin

			// transmission of 8 data bits
			if((ps2_kbd_tx_state >= 1)&&(ps2_kbd_tx_state < 9)) begin
				ps2_kbd_data <= ps2_kbd_tx_byte[0];	          // data bits
				ps2_kbd_tx_byte[6:0] <= ps2_kbd_tx_byte[7:1]; // shift down
				if(ps2_kbd_tx_byte[0]) 
					ps2_kbd_parity <= !ps2_kbd_parity;
			end

			// transmission of parity
			if(ps2_kbd_tx_state == 9) ps2_kbd_data <= ps2_kbd_parity;

			// transmission of stop bit
			if(ps2_kbd_tx_state == 10) ps2_kbd_data <= 1;    // stop bit is 1

			// advance state machine
			if(ps2_kbd_tx_state < 11) ps2_kbd_tx_state <= ps2_kbd_tx_state + 1'd1;
				else ps2_kbd_tx_state <= 0;
		end
	end
end

// mouse
reg [7:0] ps2_mouse_fifo[1<<PS2_FIFO_BITS];
reg [PS2_FIFO_BITS-1:0] ps2_mouse_wptr;
reg [PS2_FIFO_BITS-1:0] ps2_mouse_rptr;

// ps2 transmitter state machine
reg [3:0] ps2_mouse_tx_state;
reg [7:0] ps2_mouse_tx_byte;
reg ps2_mouse_parity;

assign ps2_mouse_clk = clk_ps2 || (ps2_mouse_tx_state == 0);

// ps2 transmitter
// Takes a byte from the FIFO and sends it in a ps2 compliant serial format.
reg ps2_mouse_r_inc;
always@(posedge clk_sys) begin
	reg old_clk;
	old_clk <= clk_ps2;
	if(~old_clk & clk_ps2) begin
		ps2_mouse_r_inc <= 0;

		if(ps2_mouse_r_inc) ps2_mouse_rptr <= ps2_mouse_rptr + 1'd1;

		// transmitter is idle?
		if(ps2_mouse_tx_state == 0) begin
			// data in fifo present?
			if(ps2_mouse_wptr != ps2_mouse_rptr) begin
				// load tx register from fifo
				ps2_mouse_tx_byte <= ps2_mouse_fifo[ps2_mouse_rptr];
				ps2_mouse_r_inc <= 1;

				// reset parity
				ps2_mouse_parity <= 1;

				// start transmitter
				ps2_mouse_tx_state <= 1;

				// put start bit on data line
				ps2_mouse_data <= 0;			// start bit is 0
			end
		end else begin

			// transmission of 8 data bits
			if((ps2_mouse_tx_state >= 1)&&(ps2_mouse_tx_state < 9)) begin
				ps2_mouse_data <= ps2_mouse_tx_byte[0];			  // data bits
				ps2_mouse_tx_byte[6:0] <= ps2_mouse_tx_byte[7:1]; // shift down
				if(ps2_mouse_tx_byte[0]) 
					ps2_mouse_parity <= !ps2_mouse_parity;
			end

			// transmission of parity
			if(ps2_mouse_tx_state == 9) ps2_mouse_data <= ps2_mouse_parity;

			// transmission of stop bit
			if(ps2_mouse_tx_state == 10) ps2_mouse_data <= 1;	  // stop bit is 1

			// advance state machine
			if(ps2_mouse_tx_state < 11) ps2_mouse_tx_state <= ps2_mouse_tx_state + 1'd1;
				else ps2_mouse_tx_state <= 0;
		end
	end
end


///////////////////////////////   DOWNLOADING   ///////////////////////////////



reg  [7:0] data_w;
reg [24:0] addr_w;
reg        rclk   = 0;
reg cart_load_strobe = 0;

localparam UIO_FILE_TX      = 8'h53;
localparam UIO_FILE_TX_DAT  = 8'h54;
localparam UIO_FILE_INDEX   = 8'h55;
//localparam UIO_FILE_INFO    = 8'h56;													// gonna try this - lca

// data_io has its own SPI interface to the io controller
always@(posedge SPI_SCK, posedge SPI_SS2) begin
	reg  [6:0] sbuf;
	reg  [7:0] cmd;
	reg  [4:0] cnt;
	reg [24:0] addr;
   reg [31:0] offset_into_t64;
   reg [15:0] t64_end_address;															// end adress in t64 for calc prg length	
   reg [15:0] t64_prg_filesize;															// calculated filesize
	
	if(SPI_SS2) cnt <= 0;
	else begin
		rclk <= 0;

		// don't shift in last bit. It is evaluated directly
		// when writing to ram
		if(cnt != 15) sbuf <= { sbuf[5:0], SPI_DI};

		// increase target address after write
		if(rclk) addr <= addr + 1'd1;

		// count 0-7 8-15 8-15 ... 
		if(cnt < 15) cnt <= cnt + 1'd1;
			else cnt <= 8;

		// finished command byte
      if(cnt == 7) cmd <= {sbuf, SPI_DI};

		// prepare/end transmission
		if((cmd == UIO_FILE_TX) && (cnt == 15)) begin
			// prepare 
			if(SPI_DI) begin
//				addr_total_size <= addr;														//get received file size (bytes)
						case(ioctl_index[7:0]) 
							0: addr <= 25'h0;   	  // C64.ROM LOAD at 0x0000 
							1: addr <= 25'h000000; // PRG injection using load address
						  65: addr <= 25'h000000; // T64 injection using load address
						 129: addr <= 25'h200000; // TAP buffer at 2MB
						 193: addr <= 25'h100000; // CRT buffer at 1MB
//do not use							2: addr <= 25'h200000; // tape buffer at 2MB 
//							default: addr <= 25'h0; // boot rom (UNKNOWN)
						endcase
//				addr <= 0;
//				ioctl_load_address <= 0;
				ioctl_download_active <= 0;
				ioctl_download <= 1; 
			end else begin
				addr_w <= addr;
				ioctl_download <= 0;
			end
		end

		// command 0x54: UIO_FILE_TX
		if((cmd == UIO_FILE_TX_DAT) && (cnt == 15)) begin
			if (ioctl_index[7:0] == 193) begin                                   // CRT File selected
				ioctl_load_address <= 0;														// load at 0x100000 (1mb)
				ioctl_download_active <= 1;
				if(addr == 25'h100016) cart_id[15:8] <= {sbuf, SPI_DI};							// HI byte of crt file type
				if(addr == 25'h100017) cart_id[7:0] <= {sbuf, SPI_DI};							// LO byte of crt file type
				if(addr == 25'h100018) cart_exrom[7:0] <= {sbuf, SPI_DI};						// EXROM byte of crt file type
				if(addr == 25'h100019) cart_game[7:0] <= {sbuf, SPI_DI};							// GAME byte of crt file type	
				if(addr == 25'h100044) cart_packet_length [31:24] <= {sbuf, SPI_DI};			// chip packet length (header & data) highbyte
				if(addr == 25'h100045) cart_packet_length [23:16] <= {sbuf, SPI_DI};			// chip packet length (header & data)
				if(addr == 25'h100046) cart_packet_length [15:8] <= {sbuf, SPI_DI};			// chip packet length (header & data)
				if(addr == 25'h100047) cart_packet_length [7:0] <= {sbuf, SPI_DI};			// chip packet length (header & data) lowbyte
				if(addr == 25'h10004C) cart_loadaddr [15:8] <= {sbuf, SPI_DI};					// HI byte of 1st CHIP load address
				if(addr == 25'h10004D) cart_loadaddr [7:0] <= {sbuf, SPI_DI};					// LO byte of 1st CHIP load address
				if(addr == 25'h10004E) cart_bank_size [15:8] <= {sbuf, SPI_DI};				// rom image length highbyte
				if(addr == 25'h10004F) cart_bank_size [7:0] <= {sbuf, SPI_DI};					// rom image length low byte

				addr_w <= addr;
				data_w <= {sbuf, SPI_DI};
				rclk <= 1;
				
//				if (addr >= 25'h102049) cart_attached <= 1;											// cartridge attached signal TEMP LCA
//				else	
//				cart_attached <= 0;
			
				if(addr >= 25'h100000 && addr <= 25'h102049) 
				cart_load_strobe <= 1'b1;																	// cart load strobe high for x addresses
				else																								// low for rest of load 
				cart_load_strobe <= 1'b0;																	// for auto reset routine - LCA
						
			end

			if (ioctl_index[7:0] == 129) begin                                   // TAP File selected
				ioctl_load_address <= 0;														// load at 0x200000 (2mb)
				addr_w <= addr;
				data_w <= {sbuf, SPI_DI};
//				if (addr < 128) header_buffer[addr] <= data_w;  						// 128 byte buffer for header info 
				ioctl_download_active <= 1;
				rclk <= 1;
			end

			if (ioctl_index[7:0] == 65) begin                                    // T64 File selected
//				if (addr < 128) header_buffer[addr] <= {sbuf, SPI_DI};  				// 128 byte buffer for header info 
//				if (addr == 64 && {sbuf, SPI_DI} == 0)										// T64 type
				if (addr == 66) ioctl_load_address [7:0] <= {sbuf, SPI_DI};			// 66th byte is load address1
				if (addr == 67) ioctl_load_address [15:8] <= {sbuf, SPI_DI};		// 67th byte is load address2
				if (addr == 68) t64_end_address [7:0] <= {sbuf, SPI_DI};				// 68th byte is end address1
				if (addr == 69) t64_end_address [15:8] <= {sbuf, SPI_DI};		   // 69th byte is end address2								
				if (addr == 72) offset_into_t64 [7:0] <= {sbuf, SPI_DI};				// 72nd byte is t64 start address1
				if (addr == 73) offset_into_t64 [15:8] <= {sbuf, SPI_DI};			// 73rd byte is t64 start address2
				if (addr == 74) offset_into_t64 [23:16] <= {sbuf, SPI_DI};			// 74th byte is t64 start address3
				if (addr == 75) offset_into_t64 [31:24] <= {sbuf, SPI_DI};			// 75th byte is t64 start address4

				if (addr > 69) t64_prg_filesize <= t64_end_address - ioctl_load_address;  //total filesize to be loaded

				if (addr > 75 && addr >= offset_into_t64) begin
					addr_w <= addr - offset_into_t64;
					data_w <= {sbuf, SPI_DI};
					if(addr <= offset_into_t64 + t64_prg_filesize + 'd1) 
					ioctl_download_active <= 1;
					else
					ioctl_download_active <= 0;
				end				
					rclk <= 1;
			end

 			if (ioctl_index[7:0] == 1) begin                                     // PRG File selected
				if (addr == 0) ioctl_load_address [7:0] <= {sbuf, SPI_DI};			// 1st byte is load address1
				if (addr == 1) ioctl_load_address [15:8] <= {sbuf, SPI_DI};			// 2nd byte is load address2
				if (addr >= 2) begin
					addr_w <= addr - 'd2;
					data_w <= {sbuf, SPI_DI};
					ioctl_download_active <= 1;
//					rclk <= 1;
				end
					rclk <= 1;
			end

			if (ioctl_index[7:0] == 0) begin                                     // ROM File selected
				ioctl_load_address <= 0 ;
				ioctl_download_active <= 1;
					addr_w <= addr ;
					data_w <= {sbuf, SPI_DI};
//					ioctl_download_active <= 1;
					rclk <= 1;
			end

//original loading routine start
//			addr_w <= addr;
//			data_w <= {sbuf, SPI_DI};
//			if (addr < 128) header_buffer[addr] <= data_w;  							// 128 byte buffer for header info 
//			rclk <= 1;
	end
//original loading routine end
		
		
      // expose file (menu) index
      if((cmd == UIO_FILE_INDEX) && (cnt == 15)) ioctl_index <= {sbuf, SPI_DI};

	end
end




				
		
		// Lets do a RESET once a cart has been loaded
		// How do we know when its loaded ???
		// No filesize 1st so has to be a timeout from transmission !!
		// oh, mister state machine.......
				
localparam INIT = 2'd0,
				S1	= 2'd1,
				S2 = 2'd2,
				S3 = 2'd3;
				
				
				
reg [31:0] count = 'hFFFFFF;

reg [1:0] current_state = INIT; 
reg [1:0] next_state = INIT;
	
always@(posedge clk_sys) begin
if(!reset_n) begin
	current_state <= INIT;
	end
else
	begin
	current_state <= next_state;
	#1 OLD_attach_state <= attach_state;         // #1 DELAY neccesary for RESET - LCA
	end
end

always@(*)
begin
next_state = current_state;

case(current_state)
	INIT: begin							// State 1 - clear vars and wait for download to start
//			count = 'hFFFFFF;
//			cartridge_reset = 0;
			if(cart_load_strobe) 
				next_state = S1;
		end
	S1: begin							// State 2 - download counter logic
			if(count == 'd0) 
				next_state = S2;			
			
//			if(rclk && clk_sys)
//				count = 'hFFFFFF;			// still clocking bytes keep counter topped up
//			else	
//				if(count >= 1) 
//				count = count - 1'd1;	// NO BYTE ?? start countdown
		end
	S2: begin							// State 3 - cart loaded 
//			count = 'hFFFFFF;	
			next_state = S3;
		end
	S3: begin							// State 4 - RESET me baby!!!!		
//			count = 'hFFFFFF;
//			cartridge_reset = 1;
			next_state = INIT;
		end

default: begin
//			count = 'hFFFFFF;	
			next_state = INIT;	
			end
endcase

end


// state machine 1 bit outputs

//assign cartridge_reset = (current_state == 2'b11) ? 1 : 0;
always@(posedge clk_sys)
begin
	if(current_state == S3)
		cartridge_reset <= 1'b1;
	else
		cartridge_reset <= 1'b0;
		
	if(current_state == S1)
		begin
				if(rclk)
				count = 'hFFFFFF;			// still clocking bytes keep counter topped up
			else	
				if(count >= 1) 
				count = count - 1'd1;	// NO BYTE ?? start countdown	
		end
end


// cart attach / detach handling

reg attach_state = 1'b0;
reg OLD_attach_state = 1'b0;

always @(*)
begin
attach_state = OLD_attach_state;
case(OLD_attach_state)
	0:begin
		cart_attached = 0;
		if(current_state == S2)
			attach_state = 1'b1;
		end
	1:begin
		cart_attached = 1;
		if(cart_detach_key || current_state == S1)
			attach_state = 1'b0;
		end
	default:attach_state = 0;
endcase
end


/*
always@(posedge clk_sys)
begin
	OLD_attach_state <= attach_state;

	if(OLD_attach_state == 1'b0)
		begin
		cart_attached <= 1'b0;
		if(current_state == S2)
			attach_state <= 1'b1;
		end
	if(OLD_attach_state == 1'b1)
		begin
		cart_attached <= 1'b1;
		if(cart_detach_key || current_state == S1)
			attach_state <= 1'b0;
		end
end
*/









reg  [24:0] erase_mask;
wire [24:0] next_erase = (ioctl_addr + 1'd1) & erase_mask;

always@(posedge clk_sys) begin
	reg        rclkD, rclkD2;
	reg        old_force = 0;
	reg  [6:0] erase_clk_div;
	reg [24:0] end_addr;

	rclkD    <= rclk;
	rclkD2   <= rclkD;
	ioctl_wr <= 0;

	if(rclkD & ~rclkD2) begin
		if(ioctl_download_active)begin													// ready to download after getting load address
		ioctl_dout <= data_w;																// ioctl_download_active - LCA
		ioctl_addr <= addr_w;
		ioctl_wr   <= 1;
		end
	end

	if(ioctl_download) begin
		old_force     <= 0;
		ioctl_erasing <= 0;
	end else begin

		old_force <= ioctl_force_erase;
		if(ioctl_force_erase & ~old_force) begin
			ioctl_addr    <= 'h1FFFF;
			erase_mask    <= 'h1FFFF;
			end_addr      <= 'h10002;
			erase_clk_div <= 1;
			ioctl_erasing <= 1;
		end else if(ioctl_erasing) begin
			erase_clk_div <= erase_clk_div + 1'd1;
			if(!erase_clk_div) begin
				if(next_erase == end_addr) ioctl_erasing <= 0;
				else begin
					ioctl_addr <= next_erase;
					ioctl_dout <= 0;
					ioctl_wr   <= 1;
				end
			end
		end
	end
end


endmodule
