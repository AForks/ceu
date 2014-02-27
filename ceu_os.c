/* TODO: #ifdef CEU_INTS: seqno, stki, CEU_STK */

#include "ceu_os.h"

#ifdef CEU_OS
#ifdef __AVR
#include <avr/pgmspace.h>
#include "Arduino.h"
#endif
void* CEU_APP_ADDR = NULL;  /* TODO: only __AVR? */
#endif

#ifdef __AVR
#define ISR_ON  interrupts()
#define ISR_OFF noInterrupts()
#else
#define ISR_ON
#define ISR_OFF
#endif

#include <string.h>

#ifdef CEU_DEBUG
#include <stdio.h>      /* fprintf */
#include <assert.h>
#endif

#if defined(CEU_OS) || defined(CEU_DEBUG)
#include <stdlib.h>     /* malloc/free, exit */
#endif

/* TODO: app */
#ifdef CEU_NEWS
#include "ceu_pool.h"
#endif

/*
 * pthread_t thread;
 * pthread_mutex_t mutex;
 * pthread_cond_t  cond;
 * pthread_self();
        Uint32 SDL_ThreadID(void);
 * pthread_create(&thread, NULL, f, &p);
        SDL_Thread *SDL_CreateThread(int (*fn)(void *), void *data);
 * pthread_mutex_lock(&mutex);
 * pthread_mutex_unlock(&mutex);
 * pthread_cond_wait(&cond, &mutex);
 * pthread_cond_signal(&cond);
*/

/**********************************************************************/

#ifdef CEU_NEWS
#ifdef CEU_RUNTESTS
#define CEU_MAX_DYNS 100
static int _ceu_dyns_ = 0;  /* check if total of alloc/free match */
#endif
#endif

#if defined(CEU_NEWS) || defined(CEU_THREADS) || defined(CEU_OS)
void* ceu_sys_malloc (size_t size) {
#ifdef CEU_NEWS
#ifdef CEU_RUNTESTS
    if (_ceu_dyns_ >= CEU_MAX_DYNS)
        return NULL;
    _ceu_dyns_++;           /* assumes no malloc fails */
#endif
#endif
    return malloc(size);
}

void ceu_sys_free (void* ptr) {
#ifdef CEU_NEWS
#ifdef CEU_RUNTESTS
    if (ptr != NULL)
        _ceu_dyns_--;
#endif
#endif
    free(ptr);
}
#endif

/**********************************************************************/

void ceu_sys_org_init (tceu_org* org, int n, int lbl, int seqno,
                       tceu_org* par_org, int par_trl)
{
    /* { evt=0, seqno=0, lbl=0 } for all trails */
    memset(&org->trls, 0, n*sizeof(tceu_trl));

#if defined(CEU_ORGS) || defined(CEU_OS)
    org->n = n;
#endif
#ifdef CEU_NEWS
    org->isDyn = 0;
    org->isSpw = 0;
#endif

    /* org.trls[0] == org.blk.trails[1] */
    org->trls[0].evt   = CEU_IN__STK;
    org->trls[0].lbl   = lbl;
    org->trls[0].seqno = seqno;

#ifdef CEU_ORGS
    if (par_org == NULL)
        return;             /* main class */

    /* re-link */
    {
        tceu_org_lnk* lst = &par_org->trls[par_trl].lnks[1];
        lst->prv->nxt = org;
        org->prv = lst->prv;
        org->nxt = (tceu_org*)lst;
        lst->prv = org;
    }
#endif  /* CEU_ORGS */
}
#ifndef CEU_ORGS
#define ceu_sys_org_init(a,b,c,d,e,f) ceu_sys_org_init(a,b,c,d,NULL,0)
#endif

/**********************************************************************/

#ifdef CEU_PSES
void ceu_pause (tceu_trl* trl, tceu_trl* trlF, int psed) {
    do {
        if (psed) {
            if (trl->evt == CEU_IN__ORG)
                trl->evt = CEU_IN__ORG_PSED;
        } else {
            if (trl->evt == CEU_IN__ORG_PSED)
                trl->evt = CEU_IN__ORG;
        }
        if ( trl->evt == CEU_IN__ORG
        ||   trl->evt == CEU_IN__ORG_PSED ) {
            trl += 2;       /* jump [fst|lst] */
        }
    } while (++trl <= trlF);

#ifdef ceu_out_wclock_set
    if (!psed) {
        ceu_out_wclock_set(0);  /* TODO: recalculate MIN clock */
                                /*       between trl => trlF   */
    }
#endif
}
#endif

/**********************************************************************/

u8 CEU_GC = 0;  /* execute __ceu_gc() when "true" */

void ceu_sys_go (tceu_app* app, int evt, tceu_evtp evtp)
{
    switch (evt) {
#ifdef CEU_ASYNCS
        case CEU_IN__ASYNC:
            app->pendingAsyncs = 0;
            break;
#endif
#ifdef CEU_WCLOCKS
        case CEU_IN__WCLOCK:
            if (app->wclk_min <= evtp.dt)
                app->wclk_late = evtp.dt - app->wclk_min;
            app->wclk_min_tmp = app->wclk_min;
            app->wclk_min     = CEU_WCLOCK_INACTIVE;
            break;
#endif
    }

    tceu_go go;
        go.evt  = evt;
        go.evtp = evtp;
        go.stki = 0;      /* stki */
#ifdef CEU_CLEAR
        go.stop = NULL;   /* stop */
#endif

    app->seqno++;

    for (;;)    /* STACK */
    {
        /* TODO: don't restart if kill is impossible (hold trl on stk) */
        go.org = app->data;    /* on pop(), always restart */
#if defined(CEU_INTS) || defined(CEU_ORGS)
_CEU_GO_CALL_ORG_:
#endif
        /* restart from org->trls[0] */
        go.trl = &go.org->trls[0];

#if defined(CEU_CLEAR) || defined(CEU_ORGS)
_CEU_GO_CALL_TRL_:  /* restart from org->trls[i] */
#endif

#ifdef CEU_DEBUG_TRAILS
#ifdef defined(CEU_ORGS) || defined(CEU_OS)
fprintf(stderr, "GO[%d]: evt=%d stk=%d org=%p [%d/%p]\n", app->seqno,
                go.evt, go.stki, go.org, go.org->n, go.org->trls);
#else
fprintf(stderr, "GO[%d]: evt=%d stk=%d [%d]\n", app->seqno,
                go.evt, go.stki, CEU_NTRAILS);
#endif
#endif

        for (;;) /* TRL // TODO(speed): only range of trails that apply */
        {        /* (e.g. events that do not escape an org) */
#ifdef CEU_CLEAR
            if (go.trl == go.stop) {    /* bounded trail traversal? */
                go.stop = NULL;           /* back to default */
                break;                      /* pop stack */
            }
#endif

            /* go.org has been traversed to the end? */
            if (go.trl ==
                &go.org->trls[
#if defined(CEU_ORGS) || defined(CEU_OS)
                    go.org->n
#else
                    CEU_NTRAILS
#endif
                ])
            {
                if (go.org == app->data) {
                    break;  /* pop stack */
                }

#ifdef CEU_ORGS
                {
                    /* hold next org/trl */
                    /* TODO(speed): jump LST */
                    tceu_org* _org = go.org->nxt;
                    tceu_trl* _trl = &_org->trls [
                                        (go.org->n == 0) ?
                                         ((tceu_org_lnk*)go.org)->lnk : 0
                                      ];

#ifdef CEU_NEWS
                    /* org has been cleared to the end? */
                    if ( go.evt == CEU_IN__CLEAR
                    &&   go.org->isDyn
                    &&   go.org->n != 0 )  /* TODO: avoids LNKs */
                    {
                        /* re-link PRV <-> NXT */
                        go.org->prv->nxt = go.org->nxt;
                        go.org->nxt->prv = go.org->prv;

                        /* FREE */
                        /* TODO: check if needed? (freed manually?) */
                        /*fprintf(stderr, "FREE: %p\n", go.org);*/
                        /* TODO(speed): avoid free if pool and blk out of scope */
#if    defined(CEU_NEWS_POOL) && !defined(CEU_NEWS_MALLOC)
                        ceu_pool_free(go.org->pool, (char*)go.org);
#elif  defined(CEU_NEWS_POOL) &&  defined(CEU_NEWS_MALLOC)
                        if (go.org->pool == NULL)
                            ceu_sys_free(go.org);
                        else
                            ceu_pool_free(go.org->pool, (char*)go.org);
#elif !defined(CEU_NEWS_POOL) &&  defined(CEU_NEWS_MALLOC)
                        ceu_sys_free(go.org);
#endif

                        /* explicit free(me) or end of spawn */
                        if (go.stop == go.org)
                            break;  /* pop stack */
                    }
#endif  /* CEU_NEWS */

                    go.org = _org;
                    go.trl = _trl;
/*fprintf(stderr, "UP[%p] %p %p\n", trl+1, go.org go.trl);*/
                    goto _CEU_GO_CALL_TRL_;
                }
#endif  /* CEU_ORGS */
            }

            /* continue traversing CUR org */
            {
#ifdef CEU_DEBUG_TRAILS
#ifdef CEU_ORGS
if (go.trl->evt==CEU_IN__ORG)
    fprintf(stderr, "\tTRY [%p] : evt=%d org=%p->%p\n",
                    go.trl, go.trl->evt,
                    &go.trl->lnks[0], &go.trl->lnks[1]);
else
#endif
    fprintf(stderr, "\tTRY [%p] : evt=%d seqno=%d lbl=%d\n",
                    go.trl, go.trl->evt, go.trl->seqno, go.trl->lbl);
#endif

                /* jump into linked orgs */
#ifdef CEU_ORGS
                if ( (go.trl->evt == CEU_IN__ORG)
#ifdef CEU_PSES
                  || (go.trl->evt==CEU_IN__ORG_PSED && go.evt==CEU_IN__CLEAR)
#endif
                   )
                {
                    /* TODO(speed): jump LST */
                    go.org = go.trl->lnks[0].nxt;   /* jump FST */
                    if (go.evt == CEU_IN__CLEAR) {
                        go.trl->evt = CEU_IN__NONE;
                    }
                    goto _CEU_GO_CALL_ORG_;
                }
#endif /* CEU_ORGS */

                switch (go.evt)
                {
                    /* "clear" event */
                    case CEU_IN__CLEAR:
                        if (go.trl->evt == CEU_IN__CLEAR)
                            goto _CEU_GO_GO_;
                        go.trl->evt = CEU_IN__NONE;
                        goto _CEU_GO_NEXT_;
                }

                /* a continuation (STK) will always appear before a
                 * matched event in the same stack level
                 */
                if ( ! (
                    (go.trl->evt==CEU_IN__STK && go.trl->stk==go.stki)
                ||
                    (go.trl->evt==go.evt && go.trl->seqno!=app->seqno)
                    /* evt!=CEU_IN__STK (never generated): comp is safe */
                    /* we use `!=´ intead of `<´ due to u8 overflow */
                ) ) {
                    goto _CEU_GO_NEXT_;
                }
_CEU_GO_GO_:
                /* execute this trail */
                go.trl->evt   = CEU_IN__NONE;
                go.trl->seqno = app->seqno;   /* don't awake again */
                go.lbl = go.trl->lbl;
            }

            {
#ifdef CEU_OS
                void* __old = CEU_APP_ADDR;
                CEU_APP_ADDR = app->addr;
#endif
                int _ret = app->code(app, &go);
#ifdef CEU_OS
                CEU_APP_ADDR = __old;
#endif

                switch (_ret) {
                    case RET_END:
#if defined(CEU_RET) || defined(CEU_OS)
                        app->isAlive = 0;
                        CEU_GC = 1;
#endif
                        goto _CEU_GO_QUIT_;
/*
                    case RET_GOTO:
                        goto _CEU_GOTO_;
*/
#if defined(CEU_CLEAR) || defined(CEU_ORGS)
                    case RET_TRL:
                        goto _CEU_GO_CALL_TRL_;
#endif
#if defined(CEU_INTS) || defined(CEU_ORGS)
                    case RET_ORG:
                        goto _CEU_GO_CALL_ORG_;
#endif
#ifdef CEU_ASYNCS
                    case RET_ASYNC:
                        app->pendingAsyncs = 1;
                        break;
#endif
                    default:
                        break;
                }
            }
_CEU_GO_NEXT_:
            /* go.trl!=CEU_IN__ORG guaranteed here */
            if (go.trl->evt!=CEU_IN__STK && go.trl->seqno!=app->seqno)
                go.trl->seqno = app->seqno-1;   /* keeps the gap tight */
            go.trl++;
        }

        if (go.stki == 0) {
            break;      /* reaction has terminated */
        }
        go.evtp = go.stk[--go.stki].evtp;
#ifdef CEU_INTS
#ifdef CEU_ORGS
        go.evto = go.stk[  go.stki].evto;
#endif
#endif
        go.evt  = go.stk[  go.stki].evt;
    }

_CEU_GO_QUIT_:;

#ifdef CEU_WCLOCKS
#ifdef ceu_out_wclock_set
    if (app->wclk_min != CEU_WCLOCK_INACTIVE)
        ceu_out_wclock_set(app->wclk_min);   /* only signal after all */
#endif
    app->wclk_late = 0;
#endif
}

int ceu_go_all (tceu_app* app)
{
    /* All code run atomically:
     * - the program is always locked as a whole
     * -    thread spawns will unlock => re-lock
     * - but program will still run to completion
     */
    app->init(app);     /* calls CEU_THREADS_MUTEX_LOCK() */

#ifdef CEU_IN_OS_START
#if defined(CEU_RET) || defined(CEU_OS)
    if (app->isAlive)
#endif
        ceu_sys_go(app, CEU_IN_OS_START, (tceu_evtp)NULL);
#endif

#ifdef CEU_ASYNCS
    while(
#if defined(CEU_RET) || defined(CEU_OS)
            app->isAlive &&
#endif
            (
#ifdef CEU_THREADS
                app->threads_n>0 ||
#endif
                app->pendingAsyncs
            ) )
    {
        ceu_sys_go(app, CEU_IN__ASYNC, (tceu_evtp)NULL);
#ifdef CEU_THREADS
        CEU_THREADS_MUTEX_UNLOCK(&app->threads_mutex);
        /* allow threads to also execute */
        CEU_THREADS_MUTEX_LOCK(&app->threads_mutex);
#endif
    }
#endif

#ifdef CEU_THREADS
    CEU_THREADS_MUTEX_UNLOCK(&app->threads_mutex);
#endif

#ifdef CEU_NEWS
#ifdef CEU_RUNTESTS
    assert(_ceu_dyns_ == 0);
#endif
#endif

#ifdef CEU_RET
    return app->ret;
#else
    return 0;
#endif
}

#ifdef CEU_OS

/* SYS_VECTOR
 */
void* CEU_SYS_VEC[CEU_SYS_MAX] __attribute__((used)) = {
    (void*) &ceu_sys_malloc,
    (void*) &ceu_sys_free,
    (void*) &ceu_sys_load,
    (void*) &ceu_sys_start,
    (void*) &ceu_sys_link,
    (void*) &ceu_sys_unlink,
    (void*) &ceu_sys_emit,
    (void*) &ceu_sys_call,
    (void*) &ceu_sys_go,
    (void*) &ceu_sys_org_init,
};

/*****************************************************************************
 * QUEUE
 * - 256 avoids doing modulo operations
 * - n: number of entries
 * - 0: next position to consume
 * - i: next position to enqueue
 */
#if CEU_QUEUE_MAX == 256
    char QUEUE[CEU_QUEUE_MAX];
    int  QUEUE_tot = 0;
    u8   QUEUE_get = 0;
    u8   QUEUE_put = 0;
#else
    char QUEUE[CEU_QUEUE_MAX];
    int  QUEUE_tot = 0;
    u16  QUEUE_get = 0;
    u16  QUEUE_put = 0;
#endif

tceu_queue* ceu_sys_queue_get (void) {
    tceu_queue* ret;
    ISR_OFF;
    if (QUEUE_tot == 0) {
        ret = NULL;
    } else {
#ifdef CEU_DEBUG
        assert(QUEUE_tot > 0);
#endif
        ret = (tceu_queue*) &QUEUE[QUEUE_get];
    }
    ISR_ON;
    return ret;
}

int ceu_sys_queue_put (tceu_app* app, tceu_nevt evt, tceu_evtp param,
                       int sz, char* buf) {
    ISR_OFF;

    int n = sizeof(tceu_queue) + sz;

    if (QUEUE_tot+n > CEU_QUEUE_MAX)
        return 0;   /* TODO: add event FULL when CEU_QUEUE_MAX-1 */

    /* An event+data must be continuous in the QUEUE. */
    if (QUEUE_put+n+sizeof(tceu_queue)>=CEU_QUEUE_MAX && evt!=CEU_IN__NONE) {
        int fill = CEU_QUEUE_MAX - QUEUE_put - sizeof(tceu_queue);
        /*_ceu_sys_emit(app, CEU_IN__NONE, param, fill, NULL);*/
        tceu_queue* qu = (tceu_queue*) &QUEUE[QUEUE_put];
        qu->app = app;
        qu->evt = CEU_IN__NONE;
        qu->sz  = fill;
        QUEUE_put += sizeof(tceu_queue) + fill;
        QUEUE_tot += sizeof(tceu_queue) + fill;
    }

    {
        tceu_queue* qu = (tceu_queue*) &QUEUE[QUEUE_put];
        qu->app = app;
        qu->evt = evt;
        qu->sz  = sz;

        if (sz == 0) {
            /* "param" is self-contained */
            qu->param = param;
        } else {
            /* "param" points to "buf" */
            qu->param.ptr = qu->buf;
            memcpy(qu->buf, buf, sz);
        }
    }
    QUEUE_put += n;
    QUEUE_tot += n;

    ISR_ON;
    return 1;
}

void ceu_sys_queue_rem (void) {
    ISR_OFF;
    tceu_queue* qu = (tceu_queue*) &QUEUE[QUEUE_get];
    QUEUE_tot -= sizeof(tceu_queue) + qu->sz;
    QUEUE_get += sizeof(tceu_queue) + qu->sz;
    ISR_ON;
}

/*****************************************************************************/

static tceu_app* CEU_APPS = NULL;
static tceu_lnk* CEU_LNKS = NULL;

#ifdef CEU_RET
    int ok  = 0;
    int ret = 0;
#endif

/* TODO: remove this */
int ceu_sys_emit (tceu_app* app, tceu_nevt evt, tceu_evtp param,
                  int sz, char* buf) {
    return ceu_sys_queue_put(app, evt, param, sz, buf);
}

tceu_evtp ceu_sys_call (tceu_app* app, tceu_nevt evt, tceu_evtp param) {
    tceu_lnk* lnk = CEU_LNKS;
    for (; lnk; lnk=lnk->nxt)
    {
        if (app!=lnk->src_app || evt!=lnk->src_evt)
            continue;
        if (! lnk->dst_app->isAlive)
            continue;   /* TODO: remove when unlink on stop */
#ifdef CEU_OS
        void* __old = CEU_APP_ADDR;
        CEU_APP_ADDR = lnk->dst_app->addr;
#endif
        tceu_evtp ret = lnk->dst_app->calls(lnk->dst_app, lnk->dst_evt, param);
#ifdef CEU_OS
        CEU_APP_ADDR = __old;
#endif
        return ret;
    }
/* TODO: error? */
    return (tceu_evtp)NULL;
}

static void _ceu_sys_unlink (tceu_lnk* lnk) {
    /* remove as head */
    if (CEU_LNKS == lnk) {
        CEU_LNKS = lnk->nxt;
/* TODO: prv */
    /* remove in the middle */
    } else {
        tceu_lnk* cur = CEU_LNKS;
        while (cur->nxt!=NULL && cur->nxt!=lnk)
			cur = cur->nxt;
		if (cur->nxt != NULL)
            cur->nxt = lnk->nxt;
	}

    /*lnk->nxt = NULL;*/
    ceu_sys_free(lnk);
}

static void __ceu_gc (void)
{
    if (! CEU_GC) return;
    CEU_GC = 0;

    /* remove pending events */
    {
        ISR_OFF;
        int i = 0;
        while (i < QUEUE_tot) {
            tceu_queue* qu = (tceu_queue*) &QUEUE[QUEUE_get+i];
            if (qu->app!=NULL && !qu->app->isAlive) {
                qu->evt = CEU_IN__NONE;
            }
            i += sizeof(tceu_queue) + qu->sz;
        }
        ISR_ON;
    }

    /* remove broken links */
    {
        tceu_lnk* cur = CEU_LNKS;
        while (cur != NULL) {
            tceu_lnk* nxt = cur->nxt;
            if (!cur->src_app->isAlive || !cur->dst_app->isAlive)
                _ceu_sys_unlink(cur);
            cur = nxt;
        }
    }

    /* remove dead apps */
    tceu_app* app = CEU_APPS;
    tceu_app* prv = NULL;
    while (app)
    {
        tceu_app* nxt = app->nxt;

        if (app->isAlive) {
            prv = app;

        } else {
            if (CEU_APPS == app) {
                CEU_APPS = nxt;     /* remove as head */
            } else {
                prv->nxt = nxt;     /* remove in the middle */
            }

            /* unlink all "from app" or "to app" */
            ceu_sys_unlink(app,0, 0,0);
            ceu_sys_unlink(0,0, app,0);

#ifdef CEU_RET
            ok--;
            ret += app->ret;
#endif

            /* free app memory */
            ceu_sys_free(app->data);
            ceu_sys_free(app);
        }

        app = nxt;
    }
}

int ceu_scheduler (int(*dt)())
{
    __ceu_gc();     /* apps already terminated from MAIN() */

#ifdef CEU_RET
    while (ok > 0)
#else
    while (1)
#endif
    {
        /* DT */
        int _dt = dt();
        ceu_sys_emit(NULL, CEU_IN_OS_DT, (tceu_evtp)_dt, 0, NULL);

        /* WCLOCK */
#ifdef CEU_WCLOCKS
        {
            tceu_app* app = CEU_APPS;
            while (app) {
                ceu_sys_go(app, CEU_IN__WCLOCK, (tceu_evtp)_dt);
                app = app->nxt;
            }
            __ceu_gc();
        }
#endif	/* CEU_WCLOCKS */

        /* ASYNC */
#ifdef CEU_ASYNCS
        {
            tceu_app* app = CEU_APPS;
            while (app) {
                ceu_sys_go(app, CEU_IN__ASYNC, (tceu_evtp)NULL);
                app = app->nxt;
            }
            __ceu_gc();
        }
#endif	/* CEU_ASYNCS */

        /* EVENTS */

        {
            /* clear the current size (ignore events emitted here) */
            ISR_OFF;
            int tot = QUEUE_tot;
            ISR_ON;
            while (tot > 0)
            {
                tceu_queue* qu = ceu_sys_queue_get();
                tot -= sizeof(tceu_queue) + qu->sz;
                if (qu->evt == CEU_IN__NONE) {
                    /* nothing; */
                    /* "fill event" */

                /* global events (e.g. OS_START, OS_INTERRUPT) */
                } else if (qu->app == NULL) {
                    tceu_app* app = CEU_APPS;
                    while (app) {
                        ceu_sys_go(app, qu->evt, qu->param);
                        app = app->nxt;
                    }

                } else {
                    /* linked events */
                    tceu_lnk* lnk = CEU_LNKS;
                    while (lnk) {
                        if ( qu->app==lnk->src_app
                        &&   qu->evt==lnk->src_evt
                        &&   lnk->dst_app->isAlive ) {
                            ceu_sys_go(lnk->dst_app, lnk->dst_evt, qu->param);
                        }
                        lnk = lnk->nxt;
                    }
                }

                ceu_sys_queue_rem();
            }
            __ceu_gc();
        }
    }

#ifdef CEU_RET
    return ret;
#else
    return 0;
#endif
}

/* LOAD / START */

tceu_app* ceu_sys_load (void* addr)
{
    uint       size;
    tceu_init* init;

#ifdef __AVR
    ((tceu_export) ((word)addr>>1))(&size, &init);
#else
    ((tceu_export) addr)(&size, &init);
#endif

    tceu_app* app = (tceu_app*) ceu_sys_malloc(sizeof(tceu_app));
    if (app == NULL)
        return NULL;

    app->data = (tceu_org*) ceu_sys_malloc(size);
    if (app->data == NULL)
        return NULL;

    app->sys_vec = CEU_SYS_VEC;
    app->nxt = NULL;

    /* Assumes sizeof(void*)==sizeof(WORD) and
        that gcc will word-align SIZE/INIT */
#ifdef __AVR
    app->init = (tceu_init) (((word)addr>>1) + (word)init);
#else
    app->init = (tceu_init) ((word)init);
#endif
    app->addr = addr;

    return app;
}

void ceu_sys_start (tceu_app* app)
{
    /* add as head */
	if (CEU_APPS == NULL) {
		CEU_APPS = app;

    /* add to tail */
    } else {
		tceu_app* cur = CEU_APPS;
        while (cur->nxt != NULL)
            cur = cur->nxt;
        cur->nxt = app;
    }

    /* MAX OK */
#ifdef CEU_RET
    ok++;
#endif

    /* INIT */

/*
printf(">>> %p %X %p[%x %x %x %x %x]\n", addr, size, init,
        ((unsigned char*)init)[5],
        ((unsigned char*)init)[6],
        ((unsigned char*)init)[7],
        ((unsigned char*)init)[8],
        ((unsigned char*)init)[9]);
printf("<<< %d %d\n", app->isAlive, app->ret);
*/

    app->init(app);

    /* OS_START */

#ifdef CEU_IN_OS_START
    ceu_sys_emit(NULL, CEU_IN_OS_START, (tceu_evtp)NULL, 0, NULL);
#endif
}

/* LINK & UNLINK */

int ceu_sys_link (tceu_app* src_app, tceu_nevt src_evt,
                  tceu_app* dst_app, tceu_nevt dst_evt)
{
    tceu_lnk* lnk = (tceu_lnk*) ceu_sys_malloc(sizeof(tceu_lnk));
    if (lnk == NULL)
        return 0;

    lnk->src_app = src_app;
    lnk->src_evt = src_evt;
    lnk->dst_app = dst_app;
    lnk->dst_evt = dst_evt;
    lnk->nxt = NULL;

    /* add as head */
	if (CEU_LNKS == NULL) {
		CEU_LNKS = lnk;

    /* add to tail */
    } else {
		tceu_lnk* cur = CEU_LNKS;
        while (cur->nxt != NULL)
            cur = cur->nxt;
		cur->nxt = lnk;
    }

    return 1;
}

int ceu_sys_unlink (tceu_app* src_app, tceu_nevt src_evt,
                    tceu_app* dst_app, tceu_nevt dst_evt)
{
    tceu_lnk* cur = CEU_LNKS;
    while (cur != NULL) {
        tceu_lnk* nxt = cur->nxt;
        if ( (src_app==0 || src_app==cur->src_app)
          && (src_evt==0 || src_evt==cur->src_evt)
          && (dst_app==0 || dst_app==cur->dst_app)
          && (dst_evt==0 || dst_evt==cur->dst_evt) ) {
            _ceu_sys_unlink(cur);
        }
        cur = nxt;
    }
    return 0;
}

#if 0

/* Foreach ISR, call _ceu_sys_emit directly because interrupts are already 
 * disabled.  */

#ifdef UART0_UDRE_vect
ISR(UART0_UDRE_vect, ISR_BLOCK) {
    _ceu_sys_emit(NULL,CEU_IN_OS_INTERRUPT,(tceu_evtp)UART0_UDRE_vect,0,NULL);
}
#endif

#ifdef UART_UDRE_vect
ISR(UART_UDRE_vect, ISR_BLOCK) {
    _ceu_sys_emit(NULL,CEU_IN_OS_INTERRUPT,(tceu_evtp)UART_UDRE_vect,0,NULL);
}
#endif

#ifdef USART0_UDRE_vect
ISR(USART0_UDRE_vect, ISR_BLOCK) {
    _ceu_sys_emit(NULL,CEU_IN_OS_INTERRUPT,(tceu_evtp)USART0_UDRE_vect,0,NULL);
}
#endif

#ifdef USART1_UDRE_vect
ISR(USART1_UDRE_vect, ISR_BLOCK) {
    _ceu_sys_emit(NULL,CEU_IN_OS_INTERRUPT,(tceu_evtp)USART1_UDRE_vect,0,NULL);
}
#endif

#ifdef USART_UDRE_vect
ISR(USART_UDRE_vect, ISR_BLOCK) {
    _ceu_sys_emit(NULL,CEU_IN_OS_INTERRUPT,(tceu_evtp)USART_UDRE_vect,0,NULL);
}
#endif

#ifdef USART2_UDRE_vect
ISR(USART2_UDRE_vect, ISR_BLOCK) {
    _ceu_sys_emit(NULL,CEU_IN_OS_INTERRUPT,(tceu_evtp)USART2_UDRE_vect,0,NULL);
}
#endif

#ifdef USART3_UDRE_vect
ISR(USART3_UDRE_vect, ISR_BLOCK) {
    _ceu_sys_emit(NULL,CEU_IN_OS_INTERRUPT,(tceu_evtp)USART3_UDRE_vect,0,NULL);
}
#endif

#endif /* 0 */

#endif  /* CEU_OS */
