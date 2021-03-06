DCLS = {}

local node = AST.node

local function iter_boundary (cur, id, can_cross)
    return function ()
        while cur do
            local c = cur
            cur = cur.__par
            if c.tag == 'Block' then
                return c
            elseif can_cross then
                -- continue
            elseif string.match(c.tag, '^.?Async') then
                -- see if varlist matches id to can_cross the boundary
                -- async (a,b,c) do ... end
                local can_cross2 = false

                if string.sub(id,1,1) == string.upper(string.sub(id,1,1))
                    and string.sub(id,1,1) ~= '_'
                then
                    ASR(false, cur, 'abstraction inside `async´ : not implemented') -- TODO: ID_abs is ok
                    can_cross2 = true
                end

                local _,varlist = unpack(c)
                if varlist then
                    for _, ID_int in ipairs(varlist) do
                        if ID_int[1] == id then
                            can_cross2 = true
                            break
                        end
                    end
                end
                if not can_cross2 then
                    return nil
                end
            elseif c.tag=='Data' or c.tag=='Code' or
                   c.tag=='Ext_Code' or c.tag=='Ext_Req'
            then
                return nil
            end
        end
    end
end

function DCLS.get (blk, id, can_cross)
    AST.asr(blk, 'Block')
    for blk in iter_boundary(blk,id,can_cross) do
        local dcl = blk.dcls[id]
        if dcl then
            local no = AST.iter'Vec_Init'() or AST.iter'Pool_Init'()
            if not no then
                dcl.is_used = true
            end
            return dcl
        end
    end
    return nil
end

function DCLS.asr (me, blk_or_data, id, can_cross, err)
    local data = AST.get(blk_or_data, 'Data')
    local blk = (data and AST.asr(data,'',3,'Block')) or blk_or_data
    local ret = DCLS.get(blk, id, can_cross)
    if ret then
        return ret
    else
        if data then
            ASR(false, me, 
                'invalid member access : "'..
                err..  '" has no member "'..id..'" : '..
                '`data´ "'..data.id..
                '" ('..data.ln[1]..':'..  data.ln[2]..')')
        else
            local par = AST.par(me,'Code')
            if par and par[3]==id then
                return par
            else
                ASR(false, me,
                    err..' "'..id..'" is not declared')
            end
        end
    end
end

local function dcls_new (blk, me, can_cross, opts)
assert(can_cross==nil)
    AST.asr(blk, 'Block')

    if me.n and blk.dcls[me.n..'_'] then
        return  -- revisiting this node
    end

    local id = (opts and opts.id) or me.id

    local old = DCLS.get(blk, id, can_cross)
    local implicit = (me.is_implicit and 'implicit ') or ''
    if old and (not old.is_predefined) then
        local F do
            if me.tag=='Nat'      or me.tag=='Ext' or
               me.tag=='Ext_Code' or me.tag=='Ext_Req'
            then
                F = ASR
            else
                F = WRN
            end
        end
        me.__dcls_dup = true
        F(false, me, old and
            implicit..'declaration of "'..id..'" hides previous declaration'..
                ' ('..old.ln[1]..' : line '..old.ln[2]..')')
    end

    blk.dcls[#blk.dcls+1] = me
    blk.dcls[id] = me
    if me.n then
        blk.dcls[me.n..'_'] = true
    end
    me.blk = blk
    return me
end

function DCLS.is_super (super, sub)
    assert(super.hier and sub.hier)
    if super == sub then
        return true
    elseif sub.hier.up then
        return DCLS.is_super(super, sub.hier.up)
    else
        return false
    end
end

function DCLS.base (data)
    assert(data.hier)
    if data.hier.up then
        return DCLS.base(data.hier.up)
    else
        return data
    end
end

-- native declarations are allowed until `native/end´
local native_end = false

DCLS.F = {
    -- Primitive types: id / is_num
    __prims = function (blk)
        local prims = {
            bool  = { is_num=false, is_int=false },
            byte  = { is_num=true,  is_int=true  },
            f32   = { is_num=true,  is_int=false },
            f64   = { is_num=true,  is_int=false },
            float = { is_num=true,  is_int=false },
            int   = { is_num=true,  is_int=true  },
            s16   = { is_num=true,  is_int=true  },
            s32   = { is_num=true,  is_int=true  },
            s64   = { is_num=true,  is_int=true  },
            s8    = { is_num=true,  is_int=true  },
            ssize = { is_num=true,  is_int=true  },
            u16   = { is_num=true,  is_int=true  },
            u32   = { is_num=true,  is_int=true  },
            u64   = { is_num=true,  is_int=true  },
            u8    = { is_num=true,  is_int=true  },
            uint  = { is_num=true,  is_int=true  },
            usize = { is_num=true,  is_int=true  },
            void  = { is_num=false, is_int=false },
            null  = { is_num=false, is_int=false },
            _     = { is_num=true,  is_int=true  },
        }
        for id, t in pairs(prims) do
            dcls_new(blk, {
                            tag   = 'Prim',
                            id    = id,
                            prim  = t,
                            is_used = true,
                          })
        end
    end,
    Block__PRE = function (me)
        me.dcls = {}
        if DCLS.F.__prims then
            DCLS.F.__prims(me)
            DCLS.F.__prims = nil
        end
    end,
    Block__POS = function (me)
        if AST.par(me,'Data') then
            return
        end
        local Code = AST.par(me,'Code')
        if Code and ((not Code.is_impl) or Code.is_dyn_base) then
            return
        end

        for _, dcl in ipairs(me.dcls) do
            if dcl.tag=='Data' and string.sub(dcl.id,1,1)=='_' then
                -- auto generated
            else
                local f = WRN
                if CEU.opts.ceu_err_unused then
                    f = ASR_WRN_PASS(CEU.opts.ceu_err_unused)
                end
                if dcl.tag=='Nat' and CEU.opts.ceu_err_unused_native then
                    f = ASR_WRN_PASS(CEU.opts.ceu_err_unused_native)
                elseif dcl.tag=='Code' and CEU.opts.ceu_err_unused_code then
                    f = ASR_WRN_PASS(CEU.opts.ceu_err_unused_code)
                end
                f(dcl.is_used or dcl.is_predefined, dcl,
                  AST.tag2id[dcl.tag]..' "'..dcl.id..'" declared but not used')
            end
        end
    end,
    __pass = function () end,

    ---------------------------------------------------------------------------

-- NEW

    -- LOC

    __no_abs = function (tp, no_what)
        local ID = unpack(tp)
        if ID.tag == 'ID_abs' then
            ASR(no_what and ID.dcl.tag~=no_what, tp,
                'invalid declaration : unexpected context for `'..AST.tag2id[ID.dcl.tag]..'´ "'..
                    (ID.dcl.id or ID.dcl[3])..'"')
        end
    end,

    Var__POS = function (me)
        local alias,Type,id = unpack(me)

        me.id = id
        dcls_new(AST.par(me,'Block'), me)
        DCLS.F.__no_abs(Type, 'Code')

        if alias == '&?' then
            me.is_read_only = true
            ASR(not TYPES.check(Type,'?'), me,
                'invalid declaration : option type : not implemented')
        end

        if alias then
            -- NO: alias to pointer
            --  var& int&& x = ...;
            ASR(not TYPES.check(Type,'&&'), me,
                'invalid declaration : unexpected `&&´ : cannot alias a pointer')
        end

        local ID_prim,mod = unpack(Type)
        if ID_prim.tag=='ID_prim' and ID_prim[1]=='void' and (not mod) then
            ASR(alias, me,
                'invalid declaration : variable cannot be of type `void´') 
        end

        local inits = DCLS.F.Var__POS__POS(me)
        if inits then
            return node('Stmts', me.ln, me, inits)
        end
    end,

-------------------------------------------------------------------------------

    Var__POS__POS = function (me, t)
        local is_alias,Type,id = unpack(me)

        if ((not t) and AST.par(me,'Data')) or is_alias
            or AST.par(me,'Code_Ret')
            or AST.par(me,'_Code_Pars_X')
        then
            return
        end

        if me.__dcls_ok then
            return
        end
        me.__dcls_ok = true

        local abs = TYPES.abs_dcl(Type,'Data')
        if not abs then
            return
        end

        local blk = AST.asr(abs,'', 3,'Block')

        local is_top = (not t)
        t = t or {}
        t.stmts = t.stmts or node('Stmts', me.ln)
        t.base  = t.base or node('ID_int', me.ln, id)

        for _, dcl in ipairs(blk.dcls) do
            local is_alias,tp,id,dim = unpack(dcl)
            local base = node('Exp_.', dcl.ln, '.',
                            AST.copy(t.base),
                            id)

            -- initialize vecs
            if dcl.tag == 'Var' then
                DCLS.F.Var__POS__POS(dcl, {stmts=t.stmts,base=base})
            elseif dcl.tag == 'Vec' then
                if is_alias or TYPES.is_nat(TYPES.get(tp,1)) then
                    --
                else
                    AST.insert(t.stmts, #t.stmts+1,
                        node(dcl.tag..'_Init', dcl.ln,
                            base))
                end
            end

            -- default vaules
            local stmts = AST.asr(dcl,2,'Stmts')
            local set = AST.get(stmts,'', 2,'Set_Exp') or
                        AST.get(stmts,'', 2,'Set_Any') or
                        AST.get(stmts,'', 2,'Set_Abs_Val')
            if set then
                set = AST.copy(set)
                set.__dcls_defaults = true
                AST.set(set, 2, AST.copy(base))
                AST.insert(t.stmts, #t.stmts+1, set)
            end

        end

        if AST.par(me,'_Code_Pars_X') and is_top then
            local stmts = AST.get(AST.par(me,'Code'),'',
                                    4,'Block', 1,'Stmts', 2,'Block',
                                    1,'Stmts', 1,'Do', 2,'Block', 1,'Stmts')
            if stmts then
                AST.asr(stmts,'', 1,'Code_Args')
                AST.insert(stmts, 1, t.stmts)
            else
                if #t.stmts > 0 then
                   -- code/dynamic / prototype
                    error'not implemented'
                end
            end
        else
            return t.stmts
        end
    end,

    Pool__PRE = 'Vec__PRE',
    Vec__PRE = function (me)
        local is_alias,tp,id,dim = unpack(me)
        if AST.par(me,'Data') or is_alias or TYPES.is_nat(TYPES.get(tp,1)) then
            return
        end

        if me.__dcls_ok then
            return
        end
        me.__dcls_ok = true

        return node('Stmts', me.ln,
                me,
                node(me.tag..'_Init', me.ln,
                    node('ID_int', me.ln, id)))
    end,

------------------------------------------------------------------------------

    Vec = function (me)
        local is_alias,Type,id,dim = unpack(me)
        me.id = id
        dcls_new(AST.par(me,'Block'), me)
        DCLS.F.__no_abs(Type, 'Code')

        -- vector[] void vec;
        local ID_prim,mod = unpack(Type)
        if ID_prim.tag=='ID_prim' and ID_prim[1]=='void' and (not mod) then
            ASR(false, me,
                'invalid declaration : vector cannot be of type `void´') 
        end
    end,

    Pool = function (me)
        local _,_,id,_ = unpack(me)
        me.id = id
        dcls_new(AST.par(me,'Block'), me)
    end,

    Evt = function (me)
        local _,Typelist,id = unpack(me)
        me.id = id

        -- no modifiers allowed
        for _, Type in ipairs(Typelist) do
            DCLS.F.__no_abs(Type)

            local id, mod = unpack(Type)
            assert(id.dcl,'bug found')
            ASR(id.dcl.tag=='Prim' or TYPES.is_nat_plain(Type), me,
                'invalid event type : must be primitive')
            ASR(not mod, me,
                mod and 'invalid event type : cannot use `'..mod..'´')
        end

        dcls_new(AST.par(me,'Block'), me)
    end,

-------------------------------------------------------------------------------

    -- NATIVE

    Nat_End = function (me)
        native_end = true
    end,
    Nat__PRE = function (me)
        local mod,_,id = unpack(me)
        me.id = id
        me.is_read_only = (mod == 'const')
        local blk = AST.asr(AST.root,'', 1,'Block')
        dcls_new(blk, me)

        ASR(not native_end, me,
            'native declarations are disabled')

        if id=='_{}' or id=='_char' then
            me.is_predefined = true
        end
    end,

    -- EXT

    Ext = function (me)
        local _, _, id = unpack(me)
        me.id = id
        local blk = AST.asr(AST.root,'', 1,'Block')
        dcls_new(blk, me)
    end,

    Ext_Code = 'Code',

    -- CODE / DATA

    _Code_Pars_X = function (me)
        me.tag = 'Code_Pars'
        local Code = AST.asr(me,4,'Code')
        local _,mods = unpack(Code)

        -- check types only
        do
            local tps = node('Typelist',me.ln)
            for i, dcl in ipairs(me) do
                tps[i] = dcl[2]
            end
            DCLS.F.Typelist(tps)
        end

        -- check if all mid's are "&" aliases
--[[
        if AST.asr(me,1,'Stmts')[2] == me then
            for i, dcl in ipairs(me) do
                local is_alias, Type = unpack(dcl)
                ASR(is_alias, dcl,
                    'invalid `code´ declaration : `watching´ parameter #'..i..' : expected `&´')
assert(dcl.tag=='Var' or dcl.tag=='Vec' or dcl.tag=='Evt', 'TODO')
            end
        end
]]

        local stmts = AST.asr(me,1,'Stmts')
        if stmts[2] == me then
            return  -- initialization list
        end

        -- multi-methods: changes "me.id" on Code
        me.ids_dyn = ''
        for i, dcl in ipairs(me) do
            if dcl.mods.dynamic then
                ASR(mods.dynamic, me,
                    'invalid `dynamic´ modifier : expected enclosing `code/dynamic´')
                local is_alias,Type = unpack(dcl)
                dcl.id_dyn = '_'..i..'_'..dcl.tag..
                             '_'..(is_alias and 'y' or 'n')..
                             '_'..TYPES.tostring(Type)
                dcl.id_dyn = TYPES.noc(dcl.id_dyn)
                me.ids_dyn = me.ids_dyn..dcl.id_dyn
            end
        end

        if mods.dynamic and #me>0 then
            ASR(me.ids_dyn ~= '', me,
                'invalid `dynamic´ declaration : expected dynamic parameters')
        end
    end,

    -- detect "base" dynamic multimethod: create dummy copy with plain "id"
    Code__PRE = function (me)
        local _,mods,id = unpack(me)
        if not mods.dynamic then
            return  -- not dynamic code
        end

        local old = DCLS.get(AST.par(me,'Block'), id)
        if old then
            ASR(me.is_impl, me, 'not implemented : prototype for non-base dynamic code')
            return  -- not first appearence
        end

        if me.is_dyn_base then
            return  -- not first appearence
        end

        if not me.is_impl then
            -- "base" method with plain "id"
            me.id = id
            me.is_dyn_base = true
            return
        end

        local proto_body = AST.asr(me,'', 4,'Block', 1,'Stmts')
        local orig = proto_body[2]
        AST.set(proto_body, 2, node('Stmts', me.ln))
        local new = AST.copy(me)
        AST.set(proto_body, 2, orig)

        -- "base" method with plain "id"
        new.id = id
        new.is_dyn_base = true

        local s = node('Stmts', me.ln, new, me)
        return s
    end,

    __proto_ignore = function (n1, n2)
        return (type(n1)=='string' and string.sub(n1,1,6)=='_anon_')
            or (type(n2)=='string' and string.sub(n2,1,6)=='_anon_')
            --or (AST.get(n1,'Block') and n2==nil)
    end,

    Code = function (me)
        local _,mods1,id,body1 = unpack(me)

        ASR(not AST.par(me,'Code'), me,
            'invalid `code´ declaration : nesting is not allowed')

        local blk = AST.par(me, 'Block')

        if (not me.is_dyn_base) and mods1.dynamic and me.is_impl then
            local ins1 = AST.asr(body1,'Block', 1,'Stmts', 1,'Stmts', 1,'Code_Pars')
            me.id = id..ins1.ids_dyn
            me.dyn_base = DCLS.asr(me,blk,id)
            me.dyn_base.dyn_last = me
        else
            me.id = id
        end

        local old = DCLS.get(blk, me.id)

        do
            local _n = ''
            local blk1 = AST.par(me, 'Block')
            local blk2 = AST.par(blk1,'Block') or blk1
            if blk2.__par.tag ~= 'ROOT' then
                _n = '_'..((old and old.n) or me.n)
            end
            if me.dyn_base then
                local ins1 = AST.asr(body1,'Block', 1,'Stmts', 1,'Stmts', 1,'Code_Pars')
                me.id_ = id.._n..ins1.ids_dyn
            else
                me.id_ = id.._n
            end
        end

        if old then
            local _,mods2,_,body2 = unpack(old)
            if me.is_impl then
                ASR(not (old.is_impl or old.__impl), me,
                    'invalid `code´ declaration : body for "'..id..'" already exists')
                old.__impl = true
            end

            -- compare ins
            local proto1 = AST.asr(body1,'Block',1,'Stmts',1,'Stmts')
            local proto2 = AST.asr(body2,'Block',1,'Stmts',1,'Stmts')
            local ok = AST.is_equal(proto1, proto2, DCLS.F.__proto_ignore)

            -- compare mods
            do
                for k,v in pairs(mods1) do
                    if mods2[k] ~= v then
                        ok = false
                        break
                    end
                end
                for k,v in pairs(mods2) do
                    if mods1[k] ~= v then
                        ok = false
                        break
                    end
                end
            end

            ASR(ok, me,
                'invalid `code´ declaration : unmatching prototypes '..
                '(vs. '..proto1.ln[1]..':'..proto2.ln[2]..')')
        else
            dcls_new(blk,me)
            assert(me == DCLS.get(blk,me.id))

            if not mods1.dynamic then
                dcls_new(blk,me,nil,{id=id})
                assert(me == DCLS.get(blk,id))
            end
        end
        me.is_used = (old and old.is_used)
                        or (mods1.dynamic and (not me.is_dyn_base))
    end,

    Data__PRE = function (me)
        local id, num, blk = unpack(me)
        me.id = id
        local par = AST.par(me, 'Block')

        -- check "super" path
        local super,_ = string.match(me.id, '(.*)%.(.*)')
        if super then
            local dcl = DCLS.get(par, super, true)
            ASR(dcl, me,
                'invalid declaration : abstraction "'..super..'" is not declared')
            dcl.hier = dcl.hier or { down={} }
            dcl.hier.down[#dcl.hier.down+1] = me
            me.hier = { up=dcl, down={} }

            -- copy all super vars to myself
            -- (avoid inserting empty additional Stmts to break "empty-data-dcl" detection)
            local vars = AST.asr(dcl,'', 3,'Block', 1,'Stmts')
            if #vars > 0 then
                AST.insert(AST.asr(me,'',3,'Block',1,'Stmts'), 1,
                           AST.copy(vars))
            end
        end

        me.n_vars = #AST.asr(me,'', 3,'Block', 1,'Stmts')
        dcls_new(par, me)

        me.id_ = me.id
        local blk1 = AST.par(me, 'Block')
        local blk2 = AST.par(blk1,'Block') or blk1
        if blk2.__par.tag ~= 'ROOT' then
            me.id_ = me.id..'_'..me.n
        end
    end,

    Data = function (me)
        me.weaker = 'plain'
        for _, dcl in ipairs(AST.asr(me,'',3,'Block').dcls) do
            local is_alias, tp = unpack(dcl)
            if TYPES.check(tp,'&&') then
                me.weaker = 'pointer'
                break   -- can't be worse
            elseif is_alias then
                me.weaker = 'alias'
            else
                local ID = TYPES.ID_plain(tp)
                if ID and ID.tag=='ID_abs' and ID.dcl.tag=='Data' then
                    if ID.dcl.weaker == 'pointer' then
                        me.weaker = 'pointer'
                        break   -- can't be worse
                    elseif ID.dcl.weaker == 'alias' then
                        me.weaker = 'alias'
                    end
                end
            end
        end
    end,

    Typelist = function (me)
        if #me == 1 then
            return
        end
        for _, Type in ipairs(me) do
            if Type.tag == 'Type' then
                local ID_prim,mod = unpack(Type)
                if ID_prim.tag=='ID_prim' and ID_prim[1]=='void' and (not mod) then
                    ASR(false, me,
                        'invalid declaration : unexpected type `void´')
                end
            end
        end
    end,

    ---------------------------------------------------------------------------

    --  call Ff(Dd(...));
    -- to
    --  var Dd x = Dd(...);
    --  call FF(x);

    Abs_Cons__POS = function (me)
        local code, Abslist = unpack(me)
        if code.dcl.tag ~= 'Code' then
            return
        end

        for i, v in ipairs(Abslist) do
            local id = '_'..code.n..'_'..v.n..'_abs'
            local xxx, yyy

            local data = AST.get(v,'Abs_Cons', 1,'ID_abs')
            if data and data.dcl.tag == 'Data' then
                xxx = data
                yyy = node('Set_Abs_Val', v.ln,
                        node('Abs_Val', v.ln, 'val', v),
                        node('Loc', v.ln,
                            node('ID_int', v.ln, id)))
            elseif v.tag == 'ID_any' then
                local vars = AST.asr(code.dcl,'Code', 4,'Block', 1,'Stmts', 1,'Stmts', 1,'Code_Pars')
                local _,tp = unpack(vars[i])
                if TYPES.abs_dcl(tp,'Data') then
                    xxx = tp[1]
                    yyy = node('Set_Any', v.ln,
                            v,
                            node('Loc', v.ln,
                                node('ID_int', v.ln, id)))
                end
            end

            if xxx then
                local set =
                    node('Stmts', v.ln,
                        node('Var', v.ln,
                            false,
                            node('Type', v.ln,
                                AST.copy(xxx)),
                            id),
                        yyy)

                local get = node('ID_int', v.ln, id)

                local stmts, j = AST.par(code,'Stmts')
                local t = stmts.__dcls_cons or {}
                stmts.__dcls_cons = t
                t[#t+1] = { j, set, get }

                AST.set(Abslist,i,get)
            end
        end
    end,

    Stmts__POS = function (me)
        local t = me.__dcls_cons
        if t then
            for i=#t, 1, -1 do
                local j, set, get = unpack(t[i])

                AST.insert(me, j, set)
                AST.visit_fs(set)

                get[DCLS.F] = nil
                AST.visit_fs(get)
            end
        end
    end,

    ---------------------------------------------------------------------------

-- GET: ID -> DCL

    ID_prim = function (me)
        local id = unpack(me)
        me.dcl = DCLS.asr(me, AST.par(me,'Block'), id, true, 'primitive identifier')
    end,

    ID_nat = function (me)
        local id = unpack(me)
        me.dcl = DCLS.asr(me, AST.par(me,'Block'), id, true, 'native identifier')
    end,

    ID_ext = function (me)
        local id = unpack(me)
        me.dcl = DCLS.asr(me, AST.par(me,'Block'), id, true, 'external identifier')
    end,

    ID_abs = function (me)
        local id = unpack(me)

        -- search outside current "code/data"
        local code_or_data = AST.par(me,'Code') or AST.par(me,'Data')
        local blk = (code_or_data and AST.par(code_or_data,'Block'))
                        or AST.par(me,'Block')

        me.dcl = DCLS.asr(me, blk, id, false, 'abstraction')
    end,

    ID_int = function (me)
        local id = unpack(me)
        local blk = AST.par(me,'Block')
        do
            -- escape should refer to the parent "a"
            -- var int a = do var int a; ... escape ...; end;
            local set = AST.par(me,'Set_Exp')
            if set and set.__dcls_is_escape and AST.is_par(set[2],me) then
                blk = AST.par(blk, 'Block')
            end
        end
        me.dcl = DCLS.asr(me, blk, id, false, 'internal identifier')
    end,

    ['Exp_.'] = function (me)
        local _, e, member = unpack(me)
        if e.tag == 'Outer' then
            local out = AST.par(me,'_Async_Isr') or ASR(AST.par(me,'Code'), me,
                            'invalid `outer´ : expected enclosing `code´ declaration')
            me.dcl = DCLS.asr(me, AST.par(out,'Block'),
                              member, false, 'internal identifier')
        end
    end,

    ---------------------------------------------------------------------------

    Loop_Num = function (me)
        local _, i = unpack(me)
        i.dcl.is_read_only = true
    end,

    __loop = function (me)
        return me.tag=='Loop' or me.tag=='Loop_Num' or me.tag=='Loop_Pool'
    end,
    __outer = function (me)
        local lbl = unpack(me)
        for loop in AST.iter(DCLS.F.__loop) do
            if not lbl then
                return loop
            else
                local _, id = unpack(loop)
                if id and id.dcl==lbl.dcl then
                    return loop
                end
            end
        end
    end,
    Break = function (me)
        me.outer = DCLS.F.__outer(me)
        ASR(me.outer, me,
            'invalid `break´ : expected matching enclosing `loop´')
    end,
    Continue = function (me)
        me.outer = DCLS.F.__outer(me)
        ASR(me.outer, me,
            'invalid `continue´ : expected matching enclosing `loop´')
    end,

    TODO__POS = function (me)
        local id = unpack(me)
        if id == 'escape' then
            local _, esc = unpack(me)
            local id_int1 = (esc[1]==true) or esc[1][1]
            local do_ = nil
            for n in AST.iter() do
                if string.sub(n.tag,1,5)=='Async' or
                   n.tag=='Data'  or n.tag=='Code' or
                   n.tag=='Ext_Code_impl' or n.tag=='Ext_Req_impl'
                then
                    break
                end
                if n.tag == 'Do' then
                    local id_int2 = (n[1]==true) or n[1][1]
                    if id_int1 == id_int2 then
                        do_ = n
                        break
                    end
                end
            end
            ASR(do_, esc, 'invalid `escape´ : no matching enclosing `do´')
            esc.outer = do_
            local _,_,to = unpack(do_)
            local set = AST.get(me.__par,'Set_Exp') or AST.asr(me.__par,'Set_Alias')
            set.__dcls_is_escape = true
            local fr = unpack(set)
            if to and type(to)~='boolean' then
                ASR(type(fr)~='boolean', me,
                    'invalid `escape´ : expected expression')
                to.__dcls_is_escape = true
                return AST.copy(to)
            else
                ASR(type(fr)=='boolean', me,
                    'invalid `escape´ : unexpected expression')
                set.tag = 'Nothing'
                return node('Nothing', me.ln)
            end
        else
            error'bug found'
        end
    end,
}

AST.visit(DCLS.F)
