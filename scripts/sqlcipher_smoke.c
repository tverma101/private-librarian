#include <stdio.h>
#include <string.h>
#include "sqlite3.h"

static void rm(const char *p){ remove(p); }

int main(void){
    const char *path = "/tmp/sqlcipher_smoke.db";
    const char *key = "correct-horse-battery";
    sqlite3 *db; char *err = 0; sqlite3_stmt *st;

    rm(path);
    if(sqlite3_open(path,&db)!=SQLITE_OK){ printf("FAIL open\n"); return 1; }
    if(sqlite3_key(db,key,(int)strlen(key))!=SQLITE_OK){ printf("FAIL key\n"); return 1; }
    if(sqlite3_exec(db,"PRAGMA cipher_memory_security = ON;"
                       "CREATE TABLE t(x TEXT);"
                       "INSERT INTO t VALUES('top-secret-content');",0,0,&err)!=SQLITE_OK){
        printf("FAIL exec: %s\n", err?err:"?"); return 1;
    }
    /* FTS5 must be present in this build */
    if(sqlite3_exec(db,"CREATE VIRTUAL TABLE ft USING fts5(body);"
                       "INSERT INTO ft VALUES('searchable text');",0,0,&err)!=SQLITE_OK){
        printf("FAIL fts5: %s\n", err?err:"?"); return 1;
    }
    sqlite3_close(db);

    /* Reopen WITH key */
    if(sqlite3_open(path,&db)!=SQLITE_OK){ printf("FAIL reopen\n"); return 1; }
    sqlite3_key(db,key,(int)strlen(key));
    if(sqlite3_prepare_v2(db,"SELECT x FROM t",-1,&st,0)!=SQLITE_OK){ printf("FAIL prep: %s\n", sqlite3_errmsg(db)); return 1; }
    int rc = sqlite3_step(st);
    char valbuf[128] = "(none)";
    if(rc==SQLITE_ROW){ const unsigned char *v = sqlite3_column_text(st,0); snprintf(valbuf,sizeof(valbuf),"%s", v?(const char*)v:"(null)"); }
    const char *val = valbuf;
    printf("with-key read rc=%d val=%s\n", rc, val);
    sqlite3_finalize(st);
    sqlite3_close(db);

    /* Reopen WITHOUT key -> must be denied */
    sqlite3_open(path,&db);
    sqlite3_prepare_v2(db,"SELECT x FROM t",-1,&st,0);
    rc = sqlite3_step(st);
    printf("no-key read rc=%d err=%s\n", rc, sqlite3_errmsg(db));
    int denied = !(rc==SQLITE_ROW);
    sqlite3_finalize(st);
    sqlite3_close(db);

    /* Wrong key -> also denied */
    sqlite3_open(path,&db);
    sqlite3_key(db,"wrong-key",(int)strlen("wrong-key"));
    sqlite3_prepare_v2(db,"SELECT x FROM t",-1,&st,0);
    rc = sqlite3_step(st);
    printf("wrong-key read rc=%d\n", rc);
    int wrongDenied = !(rc==SQLITE_ROW);
    sqlite3_finalize(st);
    sqlite3_close(db);

    /* Header must NOT be plaintext "SQLite format 3\0" */
    FILE *f = fopen(path,"rb");
    unsigned char hdr[16]; size_t n = fread(hdr,1,16,f); (void)n; fclose(f);
    int plain = memcmp(hdr,"SQLite format 3",15)==0;
    printf("header plaintext=%d first-bytes=%02x%02x%02x%02x\n", plain, hdr[0],hdr[1],hdr[2],hdr[3]);

    if(denied && wrongDenied && !plain && strcmp(val,"top-secret-content")==0){
        printf("SMOKE PASS\n"); return 0;
    }
    printf("SMOKE FAIL\n"); return 2;
}
