#include <netinet/in.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define SIMPLECHAT_VERSION_MAGIC (int)0xeaae00001

#define ANSI_COLOR_BLACK   "\x1b[30m"
#define ANSI_COLOR_RED     "\x1b[31m"
#define ANSI_COLOR_GREEN   "\x1b[32m"
#define ANSI_COLOR_YELLOW  "\x1b[33m"
#define ANSI_COLOR_BLUE    "\x1b[34m"
#define ANSI_COLOR_MAGENTA "\x1b[35m"
#define ANSI_COLOR_CYAN    "\x1b[36m"
#define ANSI_COLOR_WHITE   "\x1b[37m"
#define ANSI_RESET   "\x1b[0m"
#define ANSI_ITALIC   "\x1b[3m"
#define ANSI_DIM_ITALIC   "\x1b[2;3m"
#define ANSI_CLEAR_LINE   "\x1b[2K"

#define sysmsg( F ) fprintf( stdout, ANSI_COLOR_BLUE "system | " ANSI_ITALIC ANSI_COLOR_YELLOW F ANSI_RESET "\n" ); fflush( stdout );
#define sysmsgf( F, V... ) fprintf( stdout, ANSI_COLOR_BLUE "system | " ANSI_ITALIC ANSI_COLOR_YELLOW F ANSI_RESET "\n", V ); fflush( stdout );
#define syserr( F ) fprintf( stdout, ANSI_COLOR_BLUE "system | " ANSI_ITALIC ANSI_COLOR_RED F ANSI_RESET "\n" ); fflush( stdout );
#define syserrf( F, V... ) fprintf( stdout, ANSI_COLOR_BLUE "system | " ANSI_ITALIC ANSI_COLOR_RED F ANSI_RESET "\n", V ); fflush( stdout );

#define H(V) handler(V)

int handler( int res ) {
    if ( res == -1 ) {
		perror( ANSI_COLOR_BLUE "system | " ANSI_ITALIC ANSI_COLOR_RED "Error" ANSI_RESET );
		exit( -1 );
		return -1;
    }

    return res;
}

#define cmdsize(V) sizeof( CommandType ) + sizeof( V )

#define MAX_ID 64
#define MAX_USERS 64

typedef enum CommandType {
	_ = 0,
	CONNECT = 1,
	CONNECT_ACK = 2,
	DISCONNECT = 3,
	SEND = 4,
	LIST_USERS = 5,
} CommandType;

typedef struct CommandConnect {
	char nickname[MAX_ID];
} CommandConnect;

typedef struct CommandEcho {
	int magic;
} CommandEcho;

typedef struct CommandList {
	unsigned int len;
	char arr[MAX_USERS][MAX_ID];
} CommandList;

typedef struct CommandSend {
	char user[MAX_ID];
	// char target[MAX_ID + 1];
	char message[2048];
} CommandSend;

typedef union CommandPayload {
	CommandConnect connect;
	CommandEcho echo;
	CommandList list;
	CommandSend send;
} CommandPayload;

typedef struct Command {
	CommandType type;
	CommandPayload payload;
} Command;

void sendCmd( int socket, Command* cmd, struct sockaddr_in* target ) {
	size_t len = 0;
	switch ( cmd->type ) {
		case CONNECT:
			len = cmdsize( CommandConnect );
			break;
		case SEND:
			len = sizeof( CommandType ) + offsetof( CommandSend, message ) + strlen( cmd->payload.send.message );
			break;
		case LIST_USERS:
			len = sizeof( CommandType ) + offsetof( CommandList, arr ) + cmd->payload.list.len * 64;
			break;
		default:
			cmd->payload.echo.magic = SIMPLECHAT_VERSION_MAGIC;
			len = cmdsize( CommandEcho );
			break;
	}

	H( sendto( socket, cmd, len, 0, (struct sockaddr*)target, sizeof( struct sockaddr_in ) ) );
}
