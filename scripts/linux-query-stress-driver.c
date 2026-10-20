/*
 * linux-query-stress-driver.c -- runs stone_fossil_query on four threads
 * while a fifth keeps running Fossil itself (stone_fossil_run), the way the
 * app does when a conversation opens during a sync. With SQLite built
 * SQLITE_THREADSAFE=0 this crashed within seconds (SIGSEGV), which is what
 * closed the app when opening a conversation; with 2 it runs clean.
 * Usage: linux-query-stress-driver <repo.fossil> <seconds>. Exits nonzero if
 * any query failed.
 */
#include "StoneFossil.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static const char *repo; static volatile int stop = 0; static long nq = 0, nf = 0, bad = 0;
static void *querier(void *a){ (void)a;
  while(!stop){ char *out=0;
    int rc = stone_fossil_query(repo, "SELECT b.uuid, e.user, e.mtime, e.comment FROM event e JOIN blob b ON b.rid=e.objid ORDER BY e.mtime", &out);
    if(rc!=0) __atomic_add_fetch(&bad,1,__ATOMIC_RELAXED);
    free(out); __atomic_add_fetch(&nq,1,__ATOMIC_RELAXED); }
  return 0; }
static void *fossiler(void *a){ (void)a;
  while(!stop){ const char *argv[]={"timeline","-n","50","-R",repo}; char *out=0;
    stone_fossil_run(5, argv, &out); free(out); __atomic_add_fetch(&nf,1,__ATOMIC_RELAXED); }
  return 0; }
int main(int c, char **v){ repo=v[1]; int secs=atoi(v[2]); pthread_t t[5];
  for(int i=0;i<4;i++) pthread_create(&t[i],0,querier,0);
  pthread_create(&t[4],0,fossiler,0);
  sleep(secs); stop=1; for(int i=0;i<5;i++) pthread_join(t[i],0);
  printf("queries=%ld failed=%ld fossil_runs=%ld\n", nq, bad, nf); return bad ? 1 : 0; }
