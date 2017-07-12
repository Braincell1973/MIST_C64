/* CRT cartridge handling for C64 
   L.C.Ashmore 2017



*/
module cartridge
(
input romL,																			// romL signal in
input romH,																			// romH signal in
input UMAXromH,																	// romH VIC II address signal
input IOE,																			// IOE control signal
input IOF,																			// IOF control signal
input mem_write,																	// memory write active
input sdram_ce,
input sdram_we,

input clk32,																		// 32mhz clock source
input reset,																		// reset signal

input [15:0] cart_id,															// cart ID or cart type
input [15:0] cart_loadaddr,													// 1st bank loading address
input [15:0] cart_bank_size,													// length of each bank
input [31:0] cart_packet_length,												// chip packet length (header & data)
input [7:0] cart_exrom,															// CRT file EXROM status
input [7:0] cart_game,															// CRT file GAME status
input cart_attached,																// FLAG to say cart has been loaded

input [15:0] c64_mem_address_in,												// address from cpu
input [7:0] c64_data_out,														// data from cpu going to sdram

output [24:0] sdram_address_out, 											// translated address output
output exrom,																		// exrom line
output game																			// game line
//output reg nmi																	// NMI output
);

reg [15:0] romL_start_addr;													// romL start address
reg [15:0] romL_end_addr;														// romL end address
reg [15:0] romH_start_addr;													// romH start address
reg [15:0] romH_end_addr;														// romH end address

reg romH_disable;																	// FLAG to disable romH addresses *** TESTING LCA ***
	
reg [24:0] lut16k [15:0]; 														// 16k look up table for bankswitching
reg [24:0] lut8k [63:0];														// 8k look up table for bankswitching

reg [7:0] cart_bank = 0;														// cartridge bank
reg [24:0] cart_bank_offset_lo = 0;											// offset into crt file by bank * packetlength - RomL
reg [24:0] cart_bank_offset_hi = 0;											// offset into crt file by bank * packetlength - RomH

reg [24:0] addr_out ;
reg [15:0] count;

reg IOE_ena = 0;																	// FLAG to enable IOE address relocation
reg IOF_ena = 0;																	// FLAG to enable IOF address relocation
reg IOE_wr_ena = 0;																// FLAG to enable writes to IOE relocation address
reg IOF_wr_ena = 0;																// FLAG to enable writes to IOF relocation address
reg [15:0] IOE_start = 0;														// offset into current bank for IOE read/writes
reg [15:0] IOF_start = 0;														// offset into current bank for IOE read/writes

reg cart_active = 0;																// cart being accessed

reg exrom_overide = 1'b1;														// exrom overide output - bankswitching
reg game_overide = 1'b1;														// game override output - bankswitching

reg DFFF_hidden;																	// FLAG for FCIII cartridge
reg cart_disable = 0;															// FLAG to disable cartridge until RESET

reg [3:0] bankswitch = 0;


reg [24:0] cart_start = 25'h100050;											// start address in sdram for loaded carts

wire cart_size8_16k;																// cart CHIP size flag
wire ultimax_mode;

assign sdram_address_out =  addr_out ;

assign exrom = (cart_attached) ?  exrom_overide : 1'b1;
assign game = (cart_attached) ?  game_overide : 1'b1;

//assign exrom = (cart_attached) ? cart_exrom[0] : 1'b1;
//assign game = (cart_attached) ? cart_game[0] : 1'b1;

//assign exrom = 1;
//assign game = 1;
assign ultimax_mode = (game == 0 && exrom == 1) ? 1'b1 : 1'b0;						// Flag for ultimax mode

assign cart_size8_16k = (cart_bank_size > 16'h2000) ? 1'b1 : 1'b0;

//always @(posedge reset)																// lets do some stuff when reset
//begin																						// reset variables	
//		cart_bank_offset_lo <= 0;														// romL offset into SDRAM
//		cart_bank_offset_hi <= 0;														// romH offset into SDRAM
//		cart_bank <= 0;																	// current cart bank
//end

always @(posedge cart_attached)													// lets do some stuff when cart attached
begin
																								// does this cart have 16k in a single CHIP block
//	if(cart_bank_size[15:0] > 16'h2000) 
//		cart_size8_16k <= 1;																// Yep, what a freak!!!!
//		else 
//		cart_size8_16k <= 0;																// no, remember to add offset of h10 to bypass header
	
//		cart_bank_offset_lo <= 0;
//		cart_bank_offset_hi <= 0;
//		cart_bank <= 0;
end




always @(*)
begin

bankswitch  = {game,exrom};

// address range mapping for romL and romH - zero coz we dont want latches :)
romL_start_addr = 0;
romL_end_addr = 0;
romH_start_addr = 0;
romH_end_addr = 0;
romH_disable = 1'b0;

//case ({game,exrom,romL,romH})
case (bankswitch)
	// standard 8k
	4'b10: begin
//		 romL_start_addr [15:0] <= 16'h8000;		// 8k romL start address
//		 romL_end_addr [15:0] <= 16'h9FFF;			// 8k romL end address
		 romL_start_addr [15:0] = 16'h8000;	// start address from CRT
		 romL_end_addr [15:0] = 16'h9FFF;
		romH_disable = 1'b1;					// THIS SHOULNT BE NEEDED *** TESTING LCA ***
		
		 end
	// standard 8k lo
	4'b00: begin
		 romL_start_addr [15:0] = 16'h8000;		// 16k romL start address
		 romL_end_addr [15:0] = 16'h9FFF;			// 16k romL end address		 
	// standard 8k hi
		 romH_start_addr [15:0] = 16'hA000;		// 16k romH start address
		 romH_end_addr [15:0] = 16'hBFFF;			// 16k romH end address
		 end
	// ULTIMAX mode - Access with romH
	4'b01: begin
		 romL_start_addr [15:0] = 16'h8000;		// ultimax mode LO always $8000
		 romL_end_addr [15:0] = 16'h9FFF;
		 romH_start_addr [15:0] = 16'hE000;	// ultimax mode start address from CRT
		 romH_end_addr [15:0] = 16'hFFFF;
		 end
	// 16k ROM mode
	4'b11: begin
		 romL_start_addr [15:0] = 16'h8000;		// 16k romL start address
		 romL_end_addr [15:0] = 16'h9FFF;		// 16k romL end address	
		 romH_start_addr [15:0] = 16'hA000;		// 16k romH start address
		 romH_end_addr [15:0] = 16'hBFFF;		// 16k romH end address
		 end

// default: whatever goes here
endcase

end



reg [7:0] old_bank ;
reg [7:0] new_bank ;
reg [7:0] gs_bank ;

always @(posedge clk32)
begin
//	old_bank <= new_bank;
		if(c64_mem_address_in[15:8] == 'hDE)
			new_bank <= c64_mem_address_in[7:0];
//			gs_bank <= 8'h3F & c64_mem_address_in[7:0];
//		else
//			new_bank <= old_bank;
end

reg [7:0] EF_bank = 0;											// EASYFLASH BANK REGISTER - 6bit
reg [2:0] EF_ctrl = 0;											// EASYFLASH CONTROL REGISTER - only 3 bits used

always @(posedge clk32)					
begin
	if(!reset)
		begin
		EF_bank <= 0;
		EF_ctrl <= 0;
		end
	else
		begin
	if(c64_mem_address_in == 16'hDE00 && mem_write)
		EF_bank <= c64_data_out[5:0];
	if(c64_mem_address_in == 16'hDE02 && mem_write)
		EF_ctrl <= c64_data_out[2:0];
		end
end

//integer lee = 5;
// ************************************************************************************************************
// ****** CUSTOM BANKING & SPECIAL CASE LOGIC - LCA ....... Get ready for crap coding :)
// ************************************************************************************************************



//always @(c64_mem_address_in or mem_write or cart_attached or romL or romH or clk32)
always @(*)
begin
if(!reset)
	begin
	cart_disable = 0;
	cart_bank = 0;
	cart_bank_offset_lo = 0;
	cart_bank_offset_hi = 0;
	end
else

case(cart_id)
//case(lee)

	 'h0:																				// Generic 8k, 16k, ULTIMAX cart
		begin																
			exrom_overide = cart_exrom[0];									// set exrom from CRT file
			game_overide = cart_game[0] ;										// set game from CRT file
			cart_bank_offset_lo = 0;
			cart_disable = 0;
			if(cart_size8_16k)
				cart_bank_offset_hi = 'h2000;
			else
				cart_bank_offset_hi = 'h2010;
		end

	
	'h1:																				// Action Replay :) - (game 0 exrom 0 - 32k 4x 8k banks)
	begin																				// &DE00 control REGISTER
		if(cart_disable)
			begin
				exrom_overide = cart_exrom[0];									// set exrom from CRT file
				game_overide = cart_game[0] ;										// set game from CRT file						
			end
		if(c64_mem_address_in == 16'hDE00 && mem_write)	
			begin
				game_overide = c64_data_out[1];
				exrom_overide = c64_data_out[3];
				cart_disable = c64_data_out[2];	
				cart_bank_offset_lo = lut8k[{c64_data_out[4],c64_data_out[0]}];
			end
		if(IOF && !mem_write)
			IOF_start = cart_bank_offset_lo + 'h1F00;
	end


/*	
	'h3:																				// Final Cart III :) - (game 1 exrom 1 - 64k 4x 16k banks)
	begin																				// all banks @ $8000-$BFFF - switching is bank num + $40 to $DFFF
//		exrom_overide = 1;// this will reset cart on every loop!!!
//		game_overide = 1;// this will reset cart on every loop!!!
//		if(c64_mem_address_in == 16'hDFFF && mem_write)
		game_overide = 0;
		exrom_overide = 0;
		
		if(IOF && mem_write)
			begin
			DFFF_hidden = c64_data_out[7];
//			nmi <= c64_data_out[6];												// FREEZE button (key) or bit 6 = 0 generates an NMI
//			game_overide = c64_data_out[5];									// GAME forced low if freeze button (key) pressed - use below after testing
//				if(freeze_key or !c64_data_out[5])
//					game_overide <= 0;
//				else
//					game_overide <= 1;
//			exrom_overide = c64_data_out[4];									// exrom status - may need inverting LCA
			cart_bank = 'h40 - c64_data_out[3:0];							// FC3 has 4 banks - fc3+ has 16 banks of 16k
//			cart_bank_offset_lo <= (cart_bank * 'h4010);
			cart_bank_offset_lo = lut16k[cart_bank];						// switch to correct bank from LUT16K
			cart_bank_offset_hi = cart_bank_offset_lo + 'h2000;			
			end
		
		IOE_start <= cart_bank_offset_lo + 'h3E00;						// Last 2 pages visible at IOE / IOF
		IOF_start <= cart_bank_offset_lo + 'h3F00;
	end
*/

	
	'h4:																				// Simons Basic - (game 0 exrom 0 - 16k 2x 8k banks)
	begin																				// Read to IOE switches 8k config
		exrom_overide = 0;														// Write to IOE switches 16k config
		game_overide = 0;	
		cart_bank = 0;
		cart_bank_offset_lo = 0;
		cart_bank_offset_hi = 0;
		cart_disable = 0;
			if(IOE && mem_write)
				game_overide = 0;
			else
				game_overide = 1;
	end
	
	'h5:																				// Ocean Type 1 - (game 0 exrom 0 - 128k,256k or 512k in 8k banks)
	begin																				// BANK is written to lower 6 bits of $DE00 - bit 8 is always set
																						// best to mirror banks at $8000 and $A0000	
	exrom_overide = 0;															// force 16k configuration as banks mirrored
	game_overide = 0;																			
//		if(c64_mem_address_in == 16'hDE00 && mem_write)
		if(IOE && mem_write)
			begin
			cart_bank = c64_data_out[5:0];
//			cart_bank_offset_lo = (cart_bank * 'h2010);
			cart_bank_offset_lo = lut8k[cart_bank];						// switch to correct bank from LUT8K
			cart_bank_offset_hi = cart_bank_offset_lo;					// offset into crt file by bank * packetlength
			end	

	end
	
	'hA:																				// Epyx Fastload - (game 1 exrom 1 - 8k bank)
	begin
		game_overide = 1;
		cart_bank = 0;																// any access to romL or $DE00 charges a capacitor 
		cart_bank_offset_lo = 0;
		cart_bank_offset_hi = 0;
		
//		if(count == 0)
//			exrom_overide = 1;
//		else 
			exrom_overide = 0;
			
		if(clk32)																	// Once discharged the exrom drops to ON disabling cart
			begin
	//			if(c64_mem_address_in == 16'hDE00 || romL)
				if(IOE || romL)
					count = 'd16384;			
				else 
	//				if(count >= 1)
					count = count - 'b1;					
			end
	end
	
	'hD:																				// FINAL CARTRIDGE 1+2
	begin																				// 16k rom - IOE turns off rom / IOF turns rom on
		if(cart_disable)															// rom mirror at IOE/IOF
			begin
			game_overide = 1;
			exrom_overide = 1;
			end
		else
			begin
			game_overide = 0;
			exrom_overide = 0;
			end
			
		cart_bank_offset_lo = 0;
		cart_bank_offset_hi = 'h2000;
		
//		if(IOE)
//			cart_disable = 1;
		if(IOF)
			cart_disable = 0;
			
		IOE_start = 'h100050 + 'h1E00;										// Last 2 pages visible at IOE / IOF
		IOF_start = 'h100050 + 'h1F00;
		IOE_ena = 1'b1;
		IOF_ena = 1'b1;
	end
	
	
	'hF:																				// C64GS - (game 0 - exrom 1 - 64 banks of 8k)
	begin
		game_overide = 1;															// 8k config
		exrom_overide = 0;
//		game_overide = cart_game[0];
//		exrom_overide = cart_exrom[0];

		
		if(IOE && !mem_write)													// Reading from IOE ($DE00 $DEFF) switches to bank 0
			begin
				cart_bank = 0;
				cart_bank_offset_lo = 0;
				cart_bank_offset_hi = 0;
			end

		if(IOE && mem_write)
			begin
				cart_bank = new_bank;											// lowest 6 bits of address is bank
//				cart_bank = gs_bank;
//				cart_bank = c64_mem_address_in[5:0];						// lowest 6 bits of address is bank
			cart_bank_offset_lo = (cart_bank * 'h2010);
//				cart_bank_offset_lo = lut8k[cart_bank];					// switch to correct bank from LUT8K
				cart_bank_offset_hi = cart_bank_offset_lo;				// offset into crt file by bank * packetlength
				cart_bank_offset_hi = 0;
			end
	end

	
	'h11:																				// Dinamic - (game 0 - exrom 1 - 16 banks of 8k)
	begin
		game_overide = cart_game[0];
		exrom_overide = cart_exrom[0];
//		game_overide = 1;															// 8k config
//		exrom_overide = 0;

//		if(IOE && !mem_write)
		if(c64_mem_address_in == 16'hDE00 && !mem_write)
			begin
				cart_bank = c64_data_out & 8'h0F;							// lowest 4 bits of address is bank
//			cart_bank_offset_lo <= (cart_bank * 'h2010);
				cart_bank_offset_lo = lut8k[cart_bank];					// switch to correct bank from LUT8K
				cart_bank_offset_hi = 0;										// offset into crt file by bank * packetlength
			end
	end

	
	'h13:																				// Magic Desk - (game 0 exrom 1 = 4 - 16 8k banks)
	begin
		if(!cart_disable)
			begin
			game_overide = cart_game[0];										// BANK is written to lower 4 bits of $DE00 - bit 8 is always set
			exrom_overide = cart_exrom[0];									// best to mirror banks at $8000 and $A0000	
			end
		else
			begin
			exrom_overide = 1;															
			game_overide = 1;
			end
		if(c64_mem_address_in == 16'hDE00 && mem_write)
			begin
			cart_bank = {4'b0000,c64_data_out [3:0]};
//			cart_bank_offset_lo <= (cart_bank * 'h2010);
			cart_bank_offset_lo = lut8k[cart_bank];						// switch to correct bank from LUT8K
			cart_bank_offset_hi = 0;											// offset into crt file by bank * packetlength
			if(c64_data_out [7])													// BIT 7 set ?? change game / exrom lines to expose RAM
				cart_disable = 1;
			else
				cart_disable = 0;
			end
	end

/*	
	'h14:																				// Super Snapshot v5 -(64k rom 8*8k banks/4*16k banks, 32k ram 4*8k banks)
	begin																				// IOE read = cart rom mirror / NOT RAM MIRROR
		if(IOE && mem_write)														// IOE WRITE = 1 register mirrored across IOE
			begin																		// bit 6 - 7 - not connected
				cart_disable = c64_data_out [3];								// bit 5 rom/rom bank bit 2 (address line 16) (unused for 128k rom)
				exrom_overide = !c64_data_out [1];							// bit 4 rom/ram bank bit 1 (address line 15)
				game_overide = c64_data_out [0];								// bit 3 !rom enable (0:enabled, 1: disabled)
			end																		// bit 2 rom/ram bank bit 0 (address line 14)
																						// bit 1 !ram enable (0: enabled, 1:disabled), !EXROM (0:high, 1:low)
																						// bit 0 GAME (0:low, 1:high)
		if(!exrom_overide)														// exrom overide = 0 = cartridge ram disabled4
			begin																		// ROM BANKING MODE
				cart_bank_offset_lo = lut16k[{c64_data_out [5],c64_data_out [4],c64_data_out [2]}];
				cart_bank_offset_hi = cart_bank_offset_lo + 'h2000;
		//		IOE_start <= cart_bank_offset_lo + 'h1E00;				// Last ROM ONLY! page visible at $9E00 - $9EFF
			end
	end
	

	'h15:																				// Comal80 - (game 0 exrom 0 = 4 - 16k banks)
	begin
	if(cart_disable)
		begin
			game_overide = cart_game[0];										
			exrom_overide = cart_exrom[0];									
			end
		if(IOE && mem_write)														
			begin																		
				exrom_overide = c64_data_out [7];								
				game_overide = c64_data_out [6];							
				cart_disable = c64_data_out [5];								
				cart_bank_offset_lo = lut16k[c64_data_out [1:0]];
				cart_bank_offset_hi = cart_bank_offset_lo + 'h2000;
			end							
	end
*/

	'h20:																				// EASYFLASH - 1mb64 banks 8/16k
	begin
		IOF_start = 'h40000;														// RAM starts at 256k in SDRAM
		if(c64_mem_address_in == 16'hDF00)									// 256bytes of ram at reg $DF00
			begin
				if(!mem_write)														// RAM READ
					begin
						IOF_wr_ena = 0;
						IOF_ena = 1;
					end
				else
					begin
						IOF_wr_ena = 1;
						IOF_ena = 0;
					end
			end
		case(EF_ctrl[2:0])
			'b100:begin																// ROM disable - RAM still active
					cart_disable = 1;
					game_overide = 1;		
					exrom_overide = 1;
					cart_bank_offset_lo = 0;
					cart_bank_offset_hi = 0;					
					end
			'b101:begin																// ULTIMAX mode
					game_overide = 0;
					exrom_overide = 1;
					cart_bank_offset_lo = lut8k[EF_bank];
					cart_bank_offset_hi = cart_bank_offset_lo + 'h2010;
					end
			'b110:begin																// 8k CART MODE
					game_overide = 1;
					exrom_overide = 0;
					cart_bank_offset_lo = lut8k[EF_bank];
					cart_bank_offset_hi = cart_bank_offset_lo + 'h2010;
					end
			'b111:begin																// 16k CART MODE
					game_overide = 0;
					exrom_overide = 0;
					cart_bank_offset_lo = lut8k[EF_bank];
					cart_bank_offset_hi = cart_bank_offset_lo + 'h2010;
					end
			default:begin
						game_overide = 0;
						exrom_overide = 1;
						cart_bank_offset_lo = 0;
						cart_bank_offset_hi = 'h2010;
						end
			endcase
end

	'h21:																				// EASYFLASH XBANK- 1mb64 banks 8/16k
	begin
		game_overide = 0;															// 16k config
		exrom_overide = 0;
		cart_bank_offset_lo = lut8k[EF_bank];					      	// switch to correct bank from LUT8K
		cart_bank_offset_hi = cart_bank_offset_lo + 'h2010;			// offset into crt file by bank * packetlength
		
end
			
	'h39:																				// RGCD (game 0 exrom 1 = 8 banks of 8k)
	begin
			if(!cart_disable)
				begin
				game_overide = cart_game[0];									// BANK is written to lower 3 bits of $DE00 / IOE 
				exrom_overide = cart_exrom[0];								// bit 3 = diasble until next reset
				end
			else
				begin
				exrom_overide = 1;															
				game_overide = 1;
				end
			if(IOE && !mem_write)
			begin
				cart_bank = {5'b00000,c64_data_out [2:0]};				// lowest 3 bits of address is bank
//			cart_bank_offset_lo <= (cart_bank * 'h2010);
				cart_bank_offset_lo = lut8k[cart_bank];					// switch to correct bank from LUT8K
				cart_bank_offset_hi = cart_bank_offset_lo;				// offset into crt file by bank * packetlength
				
				if(c64_data_out [3])												
				cart_disable = 1;
				else
				cart_disable = 0;
			end
	end
	
	
	
	
	
	
	default:begin
//				exrom_overide = cart_exrom[0];															
//				game_overide = cart_game[0];
				exrom_overide = 1;
				game_overide = 1;
				cart_disable = 0;
				cart_bank_offset_lo = 0;
				
				if(cart_size8_16k)
				cart_bank_offset_hi = 'h2000;
			else
				cart_bank_offset_hi = 'h2010;
				end
	
endcase

end





// ************************************************************************************************************
// ****** Address handling - Redirection to SDRAM CRT file
// ************************************************************************************************************
//always @(c64_mem_address_in or mem_write or cart_attached or romL or romH or UMAXromH)
always @(*)

begin

addr_out = {9'b000000000,c64_mem_address_in};

//#10						// *** TIME DELAY TO ALLOW FOR SETUP TIME IN BANKSWITCHING - LCA ***

if(cart_attached)
	begin
	if(c64_mem_address_in >= romH_start_addr && c64_mem_address_in <= romH_end_addr) 
		begin
		if(romH && !mem_write && !romH_disable)
//				if(!mem_write)
			begin
			cart_active = 1;
				if(cart_size8_16k)																				// 16k CHIP block ??
//				   addr_out <= 'h100050 + 'h2000 + (c64_mem_address_in - romH_start_addr);		// yep
					addr_out = 25'h100050 + cart_bank_offset_hi + (c64_mem_address_in - romH_start_addr);
				else
//					addr_out <= 'h100050 + 'h2010 + (c64_mem_address_in - romH_start_addr);		// Nope
					addr_out = 25'h100050 + cart_bank_offset_hi + (c64_mem_address_in - romH_start_addr);		// Nope
//			end
				if(ultimax_mode)
					addr_out = 25'h100050 + (c64_mem_address_in - romH_start_addr);					// ULTIMAX
				if(ultimax_mode && cart_id == 'h20)
					addr_out = 25'h100050 + cart_bank_offset_hi + (c64_mem_address_in - romH_start_addr);				// ULTIMAX EASYFLASH
			end
		end
	if(c64_mem_address_in >= romL_start_addr && c64_mem_address_in <= romL_end_addr)
		begin
		if(romL && !mem_write) 
			begin
			cart_active = 1;
			if(ultimax_mode && cart_size8_16k)
				addr_out = 25'h100050 + 'h2000 + (c64_mem_address_in - romL_start_addr);
			if(ultimax_mode && cart_id == 'h20)
				addr_out = 25'h100050 + cart_bank_offset_lo + (c64_mem_address_in - romH_start_addr);				// ULTIMAX EASYFLASH		
//			else
			if(!ultimax_mode)
//				addr_out <= 'h100050 + (c64_mem_address_in - romL_start_addr);		
				addr_out = 25'h100050 + cart_bank_offset_lo + (c64_mem_address_in - romL_start_addr);	
			end
		end
	end	

//	if(c64_mem_address_in >= romL_start_addr && c64_mem_address_in <= romL_end_addr)
//		begin
		if(UMAXromH && !mem_write) 
			begin
				addr_out = 'h100050 + 'h1000 + c64_mem_address_in[11:0];		

//		end
	end

 if(IOE)
 	begin
			if(!mem_write && IOE_ena)																		// read to &DE00
				addr_out <= IOE_start + c64_mem_address_in[7:0];
			if(mem_write && IOE_wr_ena)																	// write to &DE00
				addr_out <= 'h100050 + IOE_start + c64_mem_address_in[7:0];
 	end

 if(IOF)
 	begin
			if(!mem_write && IOF_ena)																		// read to &DF00
				addr_out <= IOF_start + c64_mem_address_in[7:0];
			if(mem_write && IOF_wr_ena)																	// write to &DF00
				addr_out <= 'h100050 + IOF_start + c64_mem_address_in[7:0];
 	end

end

// ************************************************************************************************************
// ****** look-up tables - no more multiplication :D
// ************************************************************************************************************

integer offset16k;
integer offset8k;
integer index16k;
integer index8k;

initial
	begin
		offset16k = 0;
		offset8k = 0;
		for(index16k = 0; index16k < 16; index16k = index16k + 1)			// 16 position x 16k look up table
			begin																				// generates offsets into sdram
			lut16k[index16k] = offset16k;
			offset16k = 'h4010 + offset16k; 
			end
			
		for(index8k = 0; index8k < 64; index8k = index8k + 1)					// 64 position x 8k look up table
			begin																				// generates offsets into sdram
			lut8k[index8k] = offset8k;
			offset8k = 'h2010 + offset8k; 
			end
	end
	
	
endmodule
