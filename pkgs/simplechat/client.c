#include <arpa/inet.h>
#include <ctype.h>
#include <fcntl.h>
#include <locale.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <stdalign.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/poll.h>
#include <sys/socket.h>
#include <termios.h>
#include <unistd.h>

#include "util.h"

int sock = -1;
struct sockaddr_in server;
bool active = false;

void handleStdin( char* buf, size_t len ) {
	if ( active ) {
		if ( strcmp( buf, "/users" ) == 0 ) {
			printf( "\n" );
			sendCmd( sock, &(Command){ .type = LIST_USERS, .payload = { .list = { .len = 0 } } }, &server );
		} else {
			Command cmd = {
				.type = SEND,
				.payload = {
					// .send = { .target = "#test" }
				}
			};
			memcpy( cmd.payload.send.message, buf, len );
			cmd.payload.send.message[len] = 0;
			sendCmd( sock, &cmd, &server );
		}
	}
}

void handleServer( Command* cmd, size_t len ) {
	if ( !active && cmd->type == CONNECT_ACK && cmd->payload.echo.magic == SIMPLECHAT_VERSION_MAGIC ) {
		sysmsg( "CONNECT_ACK" );
		active = true;
	} else if ( active ) {
		if ( cmd->type == SEND && len > offsetof( CommandSend, message ) ) {
			printf( "\r" ANSI_COLOR_CYAN "@%s | " ANSI_RESET, cmd->payload.send.user );

			// if ( cmd->payload.send.target[0] == '@' ) {
			// 	printf( ANSI_COLOR_CYAN "%s | " ANSI_RESET, cmd->payload.send.target );
			// } else if ( cmd->payload.send.target[0] == '#' ) {
			// 	printf( ANSI_COLOR_GREEN "%s | " ANSI_RESET, cmd->payload.send.target );
			// } else {
			//	printf( ANSI_RESET "%s | ", cmd->payload.send.target );
			// }

			printf( "%s\n", cmd->payload.send.message );
		} else if ( cmd->type == DISCONNECT ) {
			sysmsg( "DISCONNECT | Server shutting down..." );
			active = false;
			shutdown( sock, SHUT_RDWR );
			close( sock );
			exit( 0 );
		} else if ( cmd->type == LIST_USERS ) {
			sysmsgf( "Available users (%u):", cmd->payload.list.len );
			for ( size_t i = 0; i < cmd->payload.list.len; i++ ) {
				sysmsgf( " - " ANSI_COLOR_CYAN "@%s", cmd->payload.list.arr[i] );
			}
		}
	}
}

Command buf;

bool validateNick( char* nick ) {
	size_t len = strlen( nick );
	if ( len < 3 || len > 63 ) {
		printf( "Nickname must be between 3-63 characters.\n" );
		return false;
	}

	for ( size_t i = 0; i < len; ++i ) {
		if ( !isalnum( nick[i] ) && nick[i] != '_' ) {
			printf( "Nickname only allows letters, digits and underscore." );
			return false;
		}
	}

	return true;
}

int main( int argc, char** argv ) {
	if ( argc != 4 || !validateNick( argv[3] ) ) {
		printf( "Usage: %s [ip] [port] [nickname]\n", argv[0] );
		return 1;
	}

	setbuf( stdout, NULL );
	// Match linux behaviour with our kernel - no stdin buffering
	struct termios info;
	tcgetattr( 0, &info );
	info.c_lflag &= ~ICANON & ~ECHO;
	info.c_cc[VMIN] = 0;
	info.c_cc[VTIME] = 0;
	tcsetattr( 0, TCSANOW, &info );

	sock = socket( PF_INET, SOCK_DGRAM, IPPROTO_UDP );
	server = (struct sockaddr_in){
		.sin_family = AF_INET,
		.sin_port = htons( atoi( argv[2] ) ),
		.sin_addr = { inet_addr( argv[1] ) }
	};
	printf( "Connecting to %s:%i...\n", inet_ntoa( server.sin_addr ), htons( server.sin_port ) );

	Command connectCmd = { .type = CONNECT };
	memcpy( connectCmd.payload.connect.nickname, argv[3], strlen( argv[3] ) );
	sendCmd( sock, &connectCmd, &server );

	struct pollfd pollfds[] = {
		{ .fd = 0, .events = POLLIN },
		{ .fd = sock, .events = POLLIN }
	};
	socklen_t slen = sizeof( struct sockaddr_in );

	char input[2048];
	int inputOff = 0;
	char inputBuf[sizeof(input) - 1];

	bool loop = true;
	while ( loop && H( poll( pollfds, sizeof( pollfds ) / sizeof( struct pollfd ), -1 ) ) > 0 ) {
		if ( pollfds[0].revents & POLLIN ) {
			int len = H( read( 0, inputBuf, sizeof( inputBuf ) ) );
			if ( len == 0 ) {
				loop = false;
				break;
			}

			for ( int i = 0; i < len; ++i ) {
				if ( inputBuf[i] == 0x03 || inputBuf[i] == 0x04 ) {
					loop = false;
					break;
				} else if ( inputBuf[i] == '\b' || inputBuf[i] == 0x7f ) {
					if ( inputOff > 0 ) {
						inputOff -= 1;
						input[inputOff] = 0;
					}
				} else if ( inputBuf[i] == '\n' ) {
					if ( inputOff > 0 ) {
						inputBuf[inputOff] = 0;
						handleStdin( input, inputOff );
					}

					input[0] = 0;
					inputOff = 0;
				} else if ( !iscntrl( inputBuf[i] ) && inputOff + 1 < (int)sizeof( input ) ) {
					input[inputOff++] = inputBuf[i];
					input[inputOff] = 0;
				}
			}
		}

		if ( pollfds[1].revents & POLLIN ) {
			struct sockaddr_in addr;
			int len = H( recvfrom( sock, &buf, sizeof( buf ), 0, (struct sockaddr*)&addr, &slen ) );
			if ( len > (int)sizeof( CommandType ) && addr.sin_addr.s_addr == server.sin_addr.s_addr ) {
				memset( (void*)&buf + len, 0, sizeof( buf ) - len );
				printf( ANSI_CLEAR_LINE "\r" );
				handleServer( &buf, len );
			}
		} else if ( pollfds[1].revents & POLLERR ) {
			char c = 0;
			H( read( sock, &c, 1 ) );
			active = false;
			break;
		}

		printf( ANSI_CLEAR_LINE "\r> %s", input );
	}

	printf( "\nShutting down...\n" );
	if ( active ) {
		sendCmd( sock, &(Command){ .type = DISCONNECT, .payload = { .echo = { .magic = 0xeaae } } }, &server );
	}
	shutdown( sock, SHUT_RDWR );
	close( sock );
	return 0;
}
