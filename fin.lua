-- Track all declared pointers to assert that they are not accessed across
-- await statements:
local TRACK = {
    --[var] = true,   -- tracking but no await yet
    --[var] = await,  -- an "await" happened while tracking "var"
                      --   now, any access to "var" yields error
}

-- TODO: TRACK por classe?

local function node2blk (n)
    return n.fst and n.fst.blk or
           n.fst and n.fst.var and n.fst.var.blk or
           MAIN.blk_ifc
end

F = {
    Dcl_cls_pre = function (me)
        TRACK = {}  -- restart tracking for each class
    end,

    SetExp = function (me)
        local op, fr, to = unpack(me)
        to = to or AST.iter'SetBlock'()[1]

        if fr.tag == 'Ref' then
            fr = fr[1]  -- Spawn, Thread, EmitExt
        end

        local cls = CLS()

    --
    -- NON-POINTER ATTRIBUTIONS (always safe)
    --

        local noptr =  (to.tp.ptr==0 and (not to.tp.arr) and (not REF(to.tp)) and
                        ((not to.tp.ext) or TP.get(to.tp.id).plain or to.tp.plain))
                                            -- either native dcl or derived
                                            -- from s.field
        -- _r.x = (int) ...;
        noptr = noptr or
                       (fr.tp.ptr==0 and (not fr.tp.arr) and (not REF(fr.tp)) and
                        ((not fr.tp.ext) or TP.get(fr.tp.id).plain or fr.tp.plain))

        if noptr then
            ASR(op == '=', me, 1101, 'wrong operator')
            ASR(not me.fin, me, 1102, 'attribution does not require `finalize´')
            return
        end

    --
    -- POINTER ATTRIBUTIONS
    --

        -- attribution in pool iterators
        if me.__ast_iter then
            return
        end

        -- an attribution restarts tracking accesses to "to"
        -- variables or native symbols
        if (to.var and (not REF(to.var.tp))) or to.c then
                        -- do not track references
            TRACK[to.var or to.id] = true
        end

        -- constants are safe
        if fr.sval then
            ASR(op == '=', me, 1103, 'wrong operator')
            ASR(not me.fin, me, 1104, 'attribution does not require `finalize´')
            return
        end

    -- NON-CONSTANT ATTRIBUTIONS

        -- determine "to_blk": block/scope for "to"
        local to_blk
        local constr = AST.iter'Dcl_constr'()
        if constr then
            -- var T t with
            --  this.x = y;     -- blk of this is the same as block of t
            -- end;
            -- spawn T with
            --  this.x = y;     -- blk of this is the same spawn pool
            -- end
            local dcl = AST.iter'Dcl_var'()
            if dcl then
                to_blk = dcl.var.blk
            else
                assert(constr.__par.tag=='Spawn')
                local _,pool,_ = unpack(constr.__par)
                assert(assert(pool.lst).var)
                to_blk = pool.lst.var.blk
            end
        else
            -- block where variable is defined
            to_blk = node2blk(to)
        end

        local fr_blk = node2blk(fr)

    -- CHECK IF "FINALIZE" IS REQUIRED

        local func_impure, input_call = false, false
        local T = fr.lst
        if T then
            if T.tag == 'Op2_call' then
                func_impure = (T.c.mod~='@pure')
            elseif T.tag == 'EmitExt' then
                local op, ext, param = unpack(T)
                input_call = op=='call' and ext.evt.pre=='input'
            end
        end

        ASR( AST.isParent(cls, to_blk), me,
            'cannot finalize a variable defined in another class' )
            --  class T with
            --  do
            --      finalize
            --          _GLB = <...>
            --      with
            --          <...>
            --      end
            --  end

-- TODO: move to exp/ref.lua
        if func_impure or input_call or fr.tag=='RawExp' then
            -- We assume that a impure function that returns a global pointer
            -- creates memory (e.g. malloc, fopen):
            --      var void&? pa = _fopen();
            -- We assume that a RawExp that returns a global pointer
            -- creates memory (e.g. { new T }):
            --      var void&? pa = { new T() };
            -- In these cases, the return memory would persist when
            -- the local goes out of scope, hence, we require finalization.
            -- The "to" pointers must be option types `&?´.

            if to.tp.opt and to.tp.opt.ref then
                T.__fin_opt_tp = to.tp  -- return value must be packed in the "&?" type
            else
                ASR(to.tp.id == '@', me, 1105,
                    'must assign to a option reference (declared with `&?´)')
                -- var void* ptr = _malloc(1);  // no
                -- _ptr = _malloc(1);           // ok
            end

-- TODO: error code
            ASR(me.fin, me, 'attribution requires `finalize´')
                -- var void&? ptr = _malloc(1);
            if me.fin then
                to_blk.fins = to_blk.fins or {}
                table.insert(to_blk.fins, 1, me.fin)
            end
            return
        end
-- TODO: error code
        ASR(not me.fin, me, 'attribution does not require `finalize´')


    -- REFUSE THE FOLLOWING POINTER ATTRIBUTIONS:
        -- to pointers inside organisms (e.g., org.x=y)
        -- to pointers with greater scope than source
    -- (CHECK IF ":=" IS REQUIRED)

        -- refuse "org.x=y", unless "this" (inside constructor or not)
        -- "this" is easy to follow inside the single body
        -- other assignments are spread in multiple bodies
--[[
        if to.org and to.fst.tag~='This' then
-- TODO: error code
            ASR(op==':=', me,
                'organism pointer attribution only inside constructors')
                -- var T t;
                -- t.v = null;

        else
]]
            -- OK: "fr" is a pointer to org (watching makes it safe)
            -- OK: "fr" `&´ reference has bigger scope than "to"
            -- int a; int* pa; pa=&a;
            -- int a; do int* pa; pa=&a; end
            if not (
                fr.const                   or -- constants are globals
                fr.fst.tag == 'Nat'        or -- natives are globals
                (fr.tag=='Op2_call' and       -- native calls are globals
                 fr[2].fst.tag=='Nat')     or
                AST.iter'Dcl_constr'()     or -- org bodies can't hold
                (fr.org and                   -- "global:*" is global
                 fr.org.cls.id=='Global')  or
                (ENV.clss[to.tp.id] and       -- organisms must use "watching"
                 fr.tag~='Op1_&')          or -- (but avoid &org)
                me.__ast_tuple             or -- tuple attribution ok
                (   -- same class and scope of "to" <= "fr"
                    (AST.par(to_blk,'Dcl_cls') == AST.par(fr_blk,'Dcl_cls')) and
                        (   to_blk.__depth >= fr_blk.__depth            -- to <= fr
                        or (to_blk.__depth==cls.blk_ifc.__depth and     --    or
                            fr_blk.__depth==cls.blk_body.__depth)       -- ifc/bdy
                        )
                )
            ) then
                ASR(op==':=', me, 'attribution to pointer with greater scope')
                    -- NO:
                    -- var int* p;
                    -- do
                    --     var int i;
                    --     p = &i;
                    -- end
            else
-- TODO: error code
                ASR(op=='=', me, 'wrong operator')
            end
        --end

    -- FORCE @hold FOR UNSAFE ATTRIBUTIONS INSIDE FUNCTIONS

        local fun = AST.iter'Dcl_fun'()
        if op==':=' and fun and                          -- unsafe attribution
           (to_blk==cls.blk_ifc or to_blk==cls.blk_body) -- inside a function
        then                                             -- to ifc/body field
            -- must be hold
            local _, _, ins, _, _, _ = unpack(fun)
            -- functions/methods that hold pointers
            -- must annotate those arguments
            ASR(ins[fr.lst.var.funIdx][1], me, 1106, 'parameter must be `hold´')
                -- function (void* v)=>void f do
                --     _V := v;
                -- end
                -- class T with
                --     var void* a;
                -- do
                --     function (void* v)=>void f do
                --         this.a := v;
                --     end
                -- end
        end
    end,

    Dcl_var = function (me)
        if me.var.tp.ptr > 0 then
            TRACK[me.var] = true
        end
    end,

    Var = function (me)
        local set = AST.iter'SetExp'()
        if set and set[3] == me then
            return  -- re-setting variable
        end
        if not TRACK[me.var] then
            return  -- not tracking this var (not a pointer)
        end
        if TRACK[me.var]==true then
            return  -- no await happened yet
        end
        if me.var.tp.arr then
            return  -- ignore tracked vars with []
        end
        if string.sub(me.var.id,1,5)=='_tup_' then
            return  -- ignore tuple acesses
        end

        if AST.iter'Dcl_constr'() and me.__par.fst.tag=='This' then
            return  -- constructor access
        end

        -- possible dangling pointer "me.var" is accessed across await

        if me.tp.ptr>0 and ENV.clss[me.tp.id] then
            -- pointer to org: check if it is enclosed by "watching me.var"
            -- since before the first await
            for n in AST.iter('ParOr') do
                local var = n.isWatching and n.isWatching.lst and n.isWatching.lst.var
                if var==me.var and AST.isParent(n,TRACK[me.var]) then
                    return      -- ok, I'm safely watching "me.var"
                end
            end
        end

        -- invalid access!
        ASR(false, me, 1107, 'pointer access across `await´')
    end,

    Await = function (me)
        if me.tl_awaits then
            for var, _ in pairs(TRACK) do
                if TRACK[var]==true then
                    TRACK[var] = me   -- tracks the *first* await
                end
            end
        end
    end,
    AwaitN   = 'Await',

    --Block    = 'Await',
    Async_pre  = 'Await',
    Thread_pre = 'Await',
    ParOr    = 'Await',
    ParAnd   = 'Await',
    Par      = 'Await',

    --Loop     = 'Await',
    Loop = function (me)
        if me.isAwaitUntil then
            return
        else
            F.Await(me)
        end
    end,

    Finalize_pre = function (me, set, fin)
        if not fin then
            set, fin = unpack(me)
        end
        assert(fin[1].tag == 'Block')
        assert(fin[1][1].tag == 'Stmts')
        fin.active = fin[1] and fin[1][1] and
                        (#fin[1][1]>1 or
                         fin[1][1][1] and fin[1][1][1].tag~='Nothing')

        if AST.iter'Dcl_constr'() then
            ASR(not fin.active, me, 1108,
                    'constructor cannot contain `finalize´')
        end

        if set then
            -- EmitExt changes the AST
            if set.tag=='Block' then
                set = set[1][2] -- Block->Stmt->SetExp
            end
            set.fin = fin                   -- let call/set handle
        elseif fin.active then
            local blk = AST.iter'Block'()
            blk.fins = blk.fins or {}
            table.insert(blk.fins, 1, fin)  -- force finalize for this blk
        end
    end,

    Op2_call_pre = function (me)
        local _, f, exps, fin = unpack(me)
        if fin then
            F.Finalize_pre(me, me, fin)
        end
    end,

    __check_params = function (me, ins, params)
        local req = false
        for i, param in ipairs(params) do
            local hold = true
            if ins then
                hold = ins.tup[i].hold
            end
            if hold then
                -- int* pa; _f(pa);
                --  (`pa´ termination must consider `_f´)
                local r = (param.tp.ptr>0 or param.tp.ext or param.tp.arr) and
                          (not param.isConst) and
                          (not param.c or param.c.mod~='const')
                                -- except constants

                r = r and param.fst and param.fst.blk or
                    r and param.fst and param.fst.var and param.fst.var.blk
                            -- need to hold block
-- TODO: ERR 10xx
                WRN( (not r) or (not req) or (r==req),
                        me, 'invalid call (multiple scopes)')
                req = req or r
            end
        end
        return req
    end,

    Op2_call = function (me)
        local _, f, params, fin = unpack(me)

        local req = false

        if not (me.c and (me.c.mod=='@pure' or me.c.mod=='@nohold')) then
            req = F.__check_params(
                    me,
                    f.var and f.var.fun and f.var.fun.ins,
                    params)
        end

-- TODO: should yield error if requires finalize and is inside Thread?
        if AST.iter'Thread'() then
            req = false     -- impossible to run finalizers on threads
        end

        ASR((not req) or fin or AST.iter'Dcl_fun'(), me, 1109,
            'call requires `finalize´')
        ASR((not fin) or req, me, 1110, 'invalid `finalize´')

        if fin and fin.active then
            req.fins = req.fins or {}
            table.insert(req.fins, 1, fin)
        end
    end,
}

AST.visit(F)

--[[
-- EVENTS:
--
-- The event emitter may pass a pointer that is already out of scope when the
-- awaking trail uses it:
--
-- event void* e;
-- var void* v = await e;
-- await ...;   // v goes out of scope
-- *v;          // segfault
--
-- We have to force the receiving "v" to go out of scope immediatelly:
--
--  event void* e;
--  do
--      var void* v = await e;
--      await ...;   // ERROR: cannot inside the "v" enclosing do-end
--      *v;
--  end
--
-------------------------------------------------------------------------------
--
-- FUNCTIONS:
--
-- When holding a parameter, a function could do either on native globals
-- or on object fields:
--
--      function (void* v1, void* v2)=>void f do
--          this.v = v1;    // OK
--          _V     = v2;    // NO!
--      end
--
-- For object fields, the caller must write a finalizer only if the
-- parameter has a shorter scope than the object of the method call:
--
--      // w/o fin
--      var void* p;
--      var T t;
--      t.f(p);     // t == p (scope)
--
--      // w/ fin
--      var T t;
--      do
--          var void* p;
--          t.f(p)      // t > p (scope)
--              finalize with ... end;
--      end
--
-- Native globals should be forbidden because we would need two different
-- kinds of "nohold" annotations to distinguish the two scopes (object and
-- global).
--
-- Native globals can be assigned in static functions requiring finalizer
-- whenever appliable.
]]
