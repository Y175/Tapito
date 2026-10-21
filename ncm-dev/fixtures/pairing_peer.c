/* SPDX-License-Identifier: GPL-3.0-only. Standalone host TEST fixture only.
 * Direct loopback synthetic RPPairing peer; no device addresses. */
#include <stdbool.h>
#include <stdint.h>
#include <assert.h>
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static int listener(uint16_t *port){int fd=socket(AF_INET,SOCK_STREAM,0);assert(fd>=0);struct sockaddr_in a={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};assert(!bind(fd,(void *)&a,sizeof a));assert(!listen(fd,2));socklen_t n=sizeof a;assert(!getsockname(fd,(void *)&a,&n));*port=ntohs(a.sin_port);return fd;}
static bool exact(int fd,void *data,size_t size,bool writing){size_t done=0;while(done<size){ssize_t n=writing?send(fd,(char *)data+done,size-done,0):recv(fd,(char *)data+done,size-done,0);if(n<=0)return false;done+=(size_t)n;}return true;}
typedef struct {int listener;bool hold;bool greeting,m1;} peer;
static void *phone(void *ctx){peer *p=ctx;int fd=accept(p->listener,NULL,NULL);assert(fd>=0);int yes=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof yes);uint8_t header[11];char body[16385];
    if(!exact(fd,header,11,false))goto done;assert(!memcmp(header,"RPPairing",9));size_t length=((size_t)header[9]<<8)|header[10];assert(length<sizeof body);assert(exact(fd,body,length,false));body[length]=0;assert(strstr(body,"attemptPairVerify"));p->greeting=true;
    puts("GREETING");fflush(stdout);
    if(p->hold){while(recv(fd,body,sizeof body,0)>0){}goto done;}
    const char reply[]="{\"originatedBy\":\"device\",\"sequenceNumber\":0,\"message\":{\"plain\":{\"_0\":{\"response\":{\"_1\":{\"handshake\":{\"_0\":{\"wireProtocolVersion\":19}}}}}}}}";
    length=strlen(reply);header[9]=(uint8_t)(length>>8);header[10]=(uint8_t)length;assert(exact(fd,header,11,true));assert(exact(fd,(void *)reply,length,true));
    assert(exact(fd,header,11,false));assert(!memcmp(header,"RPPairing",9));length=((size_t)header[9]<<8)|header[10];assert(length<sizeof body);assert(exact(fd,body,length,false));body[length]=0;assert(strstr(body,"verifyManualPairing"));assert(!strstr(body,"setupManualPairing"));p->m1=true;
    puts("VERIFY_M1");fflush(stdout);
done:close(fd);return NULL;}
int main(int argc,char **argv){
    alarm(12); uint16_t port;
    peer mock={.listener=listener(&port),.hold=argc==2&&!strcmp(argv[1],"hold")};
    printf("%u\n",port); fflush(stdout);
    phone(&mock); assert(mock.greeting); assert(mock.hold||mock.m1);
    close(mock.listener); puts("CLOSED"); return 0;
}
