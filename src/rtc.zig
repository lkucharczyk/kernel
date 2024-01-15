const root = @import( "root" );

const Register = struct {
	const Select = 0x70;
	const Data   = 0x71;
};

const Address = struct {
	/// 0-59
	const Seconds    = 0x00;
	/// 0-59
	const Minutes    = 0x02;
	/// 0-23
	const Hours      = 0x04;
	/// 1-7, Sunday-Saturday
	const Weekday    = 0x06;
	/// 1-31
	const DayOfMonth = 0x07;
	/// 1-12
	const Month      = 0x08;
	/// 0-99
	const Year       = 0x09;
	/// 19-20
	const Century    = 0x32;

	const StatusA    = 0x0a;
	const StatusB    = 0x0b;
	const StatusC    = 0x0b;
};

fn read( addr: u8 ) u8 {
	root.arch.out( u8, Register.Select, addr );
	return root.arch.in( u8, Register.Data );
}

pub fn init() void {
	root.arch.out( u8, Register.Select, Address.StatusB );
	root.arch.out( u8, Register.Data, 0b110 ); // enable binary + 24h mode

	root.log.printUnsafe( "rtc: {:0>2}.{:0>2}.{:0>2}{:0>2} {:0>2}:{:0>2}:{:0>2} UTC ({})\n", .{
		read( Address.DayOfMonth ),
		read( Address.Month ),
		read( Address.Century ),
		read( Address.Year ),
		read( Address.Hours ),
		read( Address.Minutes ),
		read( Address.Seconds ),
		getEpoch()
	} );
}

const DAYS_IN_MONTH      = [_]u8 { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
const DAYS_IN_MONTH_LEAP = [_]u8 { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

pub fn getEpoch() i64 {
	var out: i64 = read( Address.Seconds )
		+ @as( i64, read( Address.Minutes ) ) * 60
		+ @as( i64, read( Address.Hours ) ) * 60 * 60
		+ ( @as( i64, read( Address.DayOfMonth ) ) - 1 ) * 24 * 60 * 60;

	const month = read( Address.Month );
	const year: usize = @as( usize, @intCast( read( Address.Century ) ) ) * 100 + read( Address.Year );

	const isLeap = !( year % 4 != 0 or ( year % 100 == 0 and year % 400 != 0 ) );
	const dim = if ( isLeap ) DAYS_IN_MONTH_LEAP else DAYS_IN_MONTH;

	for ( dim[0..( month - 1 )] ) |d| {
		out += @as( i64, @intCast( d ) ) * 24 * 60 * 60;
	}

	if ( year > 1970 ) {
		for ( 1970..year ) |i| {
			if ( i % 4 != 0 or ( i % 100 == 0 and i % 400 != 0 ) ) {
				out += 365 * 24 * 60 * 60;
			} else {
				out += 366 * 24 * 60 * 60;
			}
		}
	}

	return out;
}
