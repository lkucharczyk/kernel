#include <arpa/inet.h>
#include <ctype.h>
#include <netinet/in.h>
#include <netinet/ip.h>
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

typedef struct Client {
	bool active;
	struct sockaddr_in addr;
	char nickname[MAX_ID];
} Client;

#define CLIENTS_LEN MAX_USERS
Client clients[CLIENTS_LEN];

void broadcastCmd( Command* cmd ) {
	for ( size_t i = 0; i < CLIENTS_LEN; ++i ) {
		if ( clients[i].active ) {
			sendCmd( sock, cmd, &clients[i].addr );
		}
	}
}

void handleStdin( char* buf ) {
	if ( strcmp( buf, "/users" ) == 0 ) {
		printf( "\n" );
		unsigned int len = 0;

		for ( size_t i = 0; i < CLIENTS_LEN; ++i ) {
			if ( clients[i].active ) {
				++len;
			}
		}

		sysmsgf( "Available users (%u):", len );
		for ( size_t i = 0; i < CLIENTS_LEN; i++ ) {
			if ( clients[i].active ) {
				sysmsgf( " - %lu: " ANSI_COLOR_CYAN "@%s", i, clients[i].nickname );
			}
		}
	}
}

void handleClient( Command* cmd, size_t len, struct sockaddr_in addr ) {
	printf( "%s:%i ", inet_ntoa( addr.sin_addr ), htons( addr.sin_port ) );

	if ( cmd->type == CONNECT && len >= cmdsize( CommandConnect ) ) {
		printf( "| " ANSI_COLOR_YELLOW "CONNECT | " ANSI_RESET );

		size_t nlen = strlen( cmd->payload.connect.nickname );
		if ( nlen == 0 ) {
			printf( "empty nick\n" );
			return;
		}

		for ( size_t i = 0; i < CLIENTS_LEN; ++i ) {
			if ( clients[i].active && strcmp( clients[i].nickname, cmd->payload.connect.nickname ) == 0 ) {
				printf( "nick collision\n" );
				return;
			}
		}

		for ( size_t i = 0; i < CLIENTS_LEN; ++i ) {
			if (
				!clients[i].active
				|| (
					clients[i].addr.sin_addr.s_addr == addr.sin_addr.s_addr
					&& clients[i].addr.sin_port == addr.sin_port
				)
			) {
				clients[i].active = true;
				clients[i].addr = addr;
				memcpy( clients[i].nickname, cmd->payload.connect.nickname, nlen );

				printf( "client: %li @%s\n", i, clients[i].nickname );

				sendCmd( sock, &(Command){ .type = CONNECT_ACK }, &clients[i].addr );
				break;
			}
		}
	} else {
		Client* client = NULL;
		for ( size_t i = 0; i < CLIENTS_LEN; ++i ) {
			if (
				clients[i].active
				&& clients[i].addr.sin_addr.s_addr == addr.sin_addr.s_addr
				&& clients[i].addr.sin_port == addr.sin_port
			) {
				client = &clients[i];
				break;
			}
		}

		if ( client == NULL ) {
			printf( "| " ANSI_COLOR_RED "Unknown client" ANSI_RESET "\n" );
		} else {
			printf( ANSI_COLOR_GREEN "@%s" ANSI_RESET " | ", client->nickname );

			if ( cmd->type == SEND && len > offsetof( CommandSend, message ) ) {
				printf( ANSI_COLOR_YELLOW "SEND | " ANSI_RESET );

				// if ( cmd->payload.send.target[0] == '@' ) {
				// 	printf( ANSI_COLOR_GREEN "%s | " ANSI_RESET, cmd->payload.send.target );
				// } else if ( cmd->payload.send.target[0] == '#' ) {
				// 	printf( ANSI_COLOR_CYAN "%s | " ANSI_RESET, cmd->payload.send.target );
				// } else {
				// 	printf( ANSI_RESET "%s | ", cmd->payload.send.target );
				// }

				printf( "%s\n", cmd->payload.send.message );
				memcpy( cmd->payload.send.user, client->nickname, sizeof( client->nickname ) );
				broadcastCmd( cmd );
			} else if ( cmd->type == LIST_USERS ) {
				printf( ANSI_COLOR_YELLOW "LIST_USERS" ANSI_RESET "\n" );
				Command reply = { .type = LIST_USERS, .payload = { .list = { .len = 0 } } };

				for ( size_t i = 0; i < CLIENTS_LEN; ++i ) {
					if ( clients[i].active ) {
						memcpy( reply.payload.list.arr[reply.payload.list.len++], clients[i].nickname, strlen( clients[i].nickname ) );
					}
				}

				sendCmd( sock, &reply, &addr );
			} else if ( cmd->type == DISCONNECT && len >= cmdsize( CommandEcho ) ) {
				printf( ANSI_COLOR_YELLOW "DISCONNECT" ANSI_RESET "\n" );
				client->active = false;
			} else {
				printf( ANSI_COLOR_RED "Unknown command" ANSI_RESET "\n" );
			}
		}
	}
}

Command buf __attribute__((aligned(256)));
int main( int argc, char** argv ) {
	if ( argc != 2 ) {
		printf( "Usage: %s [port]\n", argv[0] );
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

	struct sockaddr_in server = {
		.sin_family = AF_INET,
		.sin_port = htons( atoi( argv[1] ) ),
		.sin_addr = { 0 }
	};
	sock = H( socket( PF_INET, SOCK_DGRAM, IPPROTO_UDP ) );
	H( bind( sock, (struct sockaddr*)&server, sizeof( struct sockaddr_in ) ) );
	printf( "Listening on %s:%i...\n", inet_ntoa( server.sin_addr ), htons( server.sin_port ) );

	struct pollfd pollfds[] = {
		{ .fd = 0, .events = POLLIN },
		{ .fd = sock, .events = POLLIN }
	};

	char input[2048];
	int inputOff = 0;
	char inputBuf[sizeof( input ) - 1];
	socklen_t slen = sizeof( struct sockaddr_in );

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
						handleStdin( input );
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
			if ( len > (int)sizeof( CommandType ) ) {
				memset( (void*)&buf + len, 0, sizeof( buf ) - len );
				printf( ANSI_CLEAR_LINE "\r" );
				handleClient( &buf, len, addr );
			}
		} else if ( pollfds[1].revents & POLLERR ) {
			char c = 0;
			H( read( sock, &c, 1 ) );
			break;
		}

		printf( ANSI_CLEAR_LINE "\r> %s", input );
	}

	printf( "Shutting down...\n" );
	broadcastCmd( &(Command){ .type = DISCONNECT } );
	shutdown( sock, SHUT_RDWR );
	close( sock );
	return 0;
}
