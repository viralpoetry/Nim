#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# included from sem.nim

discard """
  hygienic templates:

    template `||` (a, b: untyped): untyped =
      let aa = a
      if aa: aa else: b

    var
      a, b: T

    echo a || b || a

  Each evaluation context has to be different and we need to perform
  some form of preliminary symbol lookup in template definitions. Hygiene is
  a way to achieve lexical scoping at compile time.
"""

const
  errImplOfXNotAllowed = "implementation of '$1' is not allowed"

type
  TSymBinding = enum
    spNone, spGenSym, spInject

proc symBinding(n: PNode): TSymBinding =
  for i in 0..<n.len:
    var it = n[i]
    var key = if it.kind == nkExprColonExpr: it[0] else: it
    if key.kind == nkIdent:
      case whichKeyword(key.ident)
      of wGensym: return spGenSym
      of wInject: return spInject
      else: discard

type
  TSymChoiceRule = enum
    scClosed, scOpen, scForceOpen

proc symChoice(c: PContext, n: PNode, s: PSym, r: TSymChoiceRule;
               isField = false): PNode =
  var
    a: PSym
    o: TOverloadIter
  var i = 0
  a = initOverloadIter(o, c, n)
  while a != nil:
    if a.kind != skModule:
      inc(i)
      if i > 1: break
    a = nextOverloadIter(o, c, n)
  let info = getCallLineInfo(n)
  if i <= 1 and r != scForceOpen:
    # XXX this makes more sense but breaks bootstrapping for now:
    # (s.kind notin routineKinds or s.magic != mNone):
    # for instance 'nextTry' is both in tables.nim and astalgo.nim ...
    if not isField or sfGenSym notin s.flags:
      result = newSymNode(s, info)
      markUsed(c, info, s)
      onUse(info, s)
    else:
      result = n
  else:
    # semantic checking requires a type; ``fitNode`` deals with it
    # appropriately
    let kind = if r == scClosed or n.kind == nkDotExpr: nkClosedSymChoice
               else: nkOpenSymChoice
    result = newNodeIT(kind, info, newTypeS(tyNone, c))
    a = initOverloadIter(o, c, n)
    while a != nil:
      if a.kind != skModule and (not isField or sfGenSym notin a.flags):
        incl(a.flags, sfUsed)
        markOwnerModuleAsUsed(c, a)
        result.add newSymNode(a, info)
        onUse(info, a)
      a = nextOverloadIter(o, c, n)

proc semBindStmt(c: PContext, n: PNode, toBind: var IntSet): PNode =
  result = copyNode(n)
  for i in 0..<n.len:
    var a = n[i]
    # If 'a' is an overloaded symbol, we used to use the first symbol
    # as a 'witness' and use the fact that subsequent lookups will yield
    # the same symbol!
    # This is however not true anymore for hygienic templates as semantic
    # processing for them changes the symbol table...
    let s = qualifiedLookUp(c, a, {checkUndeclared})
    if s != nil:
      # we need to mark all symbols:
      let sc = symChoice(c, n, s, scClosed)
      if sc.kind == nkSym:
        toBind.incl(sc.sym.id)
        result.add sc
      else:
        for x in items(sc):
          toBind.incl(x.sym.id)
          result.add x
    else:
      illFormedAst(a, c.config)

proc semMixinStmt(c: PContext, n: PNode, toMixin: var IntSet): PNode =
  result = copyNode(n)
  var count = 0
  for i in 0..<n.len:
    toMixin.incl(considerQuotedIdent(c, n[i]).id)
    let x = symChoice(c, n[i], nil, scForceOpen)
    inc count, x.len
    result.add x
  if count == 0:
    result = newNodeI(nkEmpty, n.info)

proc replaceIdentBySym(c: PContext; n: var PNode, s: PNode) =
  case n.kind
  of nkPostfix: replaceIdentBySym(c, n[1], s)
  of nkPragmaExpr: replaceIdentBySym(c, n[0], s)
  of nkIdent, nkAccQuoted, nkSym: n = s
  else: illFormedAst(n, c.config)

type
  TemplCtx = object
    c: PContext
    toBind, toMixin, toInject: IntSet
    owner: PSym
    cursorInBody: bool # only for nimsuggest
    scopeN: int
    noGenSym: int
    inTemplateHeader: int

proc getIdentNode(c: var TemplCtx, n: PNode): PNode =
  case n.kind
  of nkPostfix: result = getIdentNode(c, n[1])
  of nkPragmaExpr: result = getIdentNode(c, n[0])
  of nkIdent:
    result = n
    let s = qualifiedLookUp(c.c, n, {})
    if s != nil:
      if s.owner == c.owner and s.kind == skParam:
        result = newSymNode(s, n.info)
  of nkAccQuoted, nkSym: result = n
  else:
    illFormedAst(n, c.c.config)
    result = n

proc isTemplParam(c: TemplCtx, n: PNode): bool {.inline.} =
  result = n.kind == nkSym and n.sym.kind == skParam and
           n.sym.owner == c.owner and sfTemplateParam in n.sym.flags

proc semTemplBody(c: var TemplCtx, n: PNode): PNode

proc openScope(c: var TemplCtx) =
  openScope(c.c)

proc closeScope(c: var TemplCtx) =
  closeScope(c.c)

proc semTemplBodyScope(c: var TemplCtx, n: PNode): PNode =
  openScope(c)
  result = semTemplBody(c, n)
  closeScope(c)

proc onlyReplaceParams(c: var TemplCtx, n: PNode): PNode =
  result = n
  if n.kind == nkIdent:
    let s = qualifiedLookUp(c.c, n, {})
    if s != nil:
      if s.owner == c.owner and s.kind == skParam:
        incl(s.flags, sfUsed)
        result = newSymNode(s, n.info)
        onUse(n.info, s)
  else:
    for i in 0..<n.safeLen:
      result[i] = onlyReplaceParams(c, n[i])

proc newGenSym(kind: TSymKind, n: PNode, c: var TemplCtx): PSym =
  result = newSym(kind, considerQuotedIdent(c.c, n), nextSymId c.c.idgen, c.owner, n.info)
  incl(result.flags, sfGenSym)
  incl(result.flags, sfShadowed)

proc addLocalDecl(c: var TemplCtx, n: var PNode, k: TSymKind) =
  # locals default to 'gensym':
  if n.kind == nkPragmaExpr and symBinding(n[1]) == spInject:
    # even if injected, don't produce a sym choice here:
    #n = semTemplBody(c, n)
    var x = n[0]
    while true:
      case x.kind
      of nkPostfix: x = x[1]
      of nkPragmaExpr: x = x[0]
      of nkIdent: break
      of nkAccQuoted:
        # consider:  type `T TemplParam` {.inject.}
        # it suffices to return to treat it like 'inject':
        n = onlyReplaceParams(c, n)
        return
      else:
        illFormedAst(x, c.c.config)
    let ident = getIdentNode(c, x)
    if not isTemplParam(c, ident):
      c.toInject.incl(x.ident.id)
    else:
      replaceIdentBySym(c.c, n, ident)
  else:
    if (n.kind == nkPragmaExpr and n.len >= 2 and n[1].kind == nkPragma):
      let pragmaNode = n[1]
      for i in 0..<pragmaNode.len:
        let ni = pragmaNode[i]
        # see D20210801T100514
        var found = false
        if ni.kind == nkIdent:
          for a in templatePragmas:
            if ni.ident == getIdent(c.c.cache, $a):
              found = true
              break
        if not found:
          openScope(c)
          pragmaNode[i] = semTemplBody(c, pragmaNode[i])
          closeScope(c)
    let ident = getIdentNode(c, n)
    if not isTemplParam(c, ident):
      if n.kind != nkSym:
        let local = newGenSym(k, ident, c)
        addPrelimDecl(c.c, local)
        styleCheckDef(c.c, n.info, local)
        onDef(n.info, local)
        replaceIdentBySym(c.c, n, newSymNode(local, n.info))
        if k == skParam and c.inTemplateHeader > 0:
          local.flags.incl sfTemplateParam
    else:
      replaceIdentBySym(c.c, n, ident)

proc semTemplSymbol(c: PContext, n: PNode, s: PSym; isField: bool): PNode =
  incl(s.flags, sfUsed)
  # bug #12885; ideally sem'checking is performed again afterwards marking
  # the symbol as used properly, but the nfSem mechanism currently prevents
  # that from happening, so we mark the module as used here already:
  markOwnerModuleAsUsed(c, s)
  # we do not call onUse here, as the identifier is not really
  # resolved here. We will fixup the used identifiers later.
  case s.kind
  of skUnknown:
    # Introduced in this pass! Leave it as an identifier.
    result = n
  of OverloadableSyms-{skTemplate,skMacro}:
    result = symChoice(c, n, s, scOpen, isField)
  of skTemplate, skMacro:
    result = symChoice(c, n, s, scOpen, isField)
    if result.kind == nkSym:
      # template/macro symbols might need to be semchecked again
      # prepareOperand etc don't do this without setting the type to nil
      result.typ = nil
  of skGenericParam:
    if isField and sfGenSym in s.flags: result = n
    else: result = newSymNodeTypeDesc(s, c.idgen, n.info)
  of skParam:
    result = n
  of skType:
    if isField and sfGenSym in s.flags: result = n
    else: result = newSymNodeTypeDesc(s, c.idgen, n.info)
  else:
    if isField and sfGenSym in s.flags: result = n
    else: result = newSymNode(s, n.info)
    # Issue #12832
    when defined(nimsuggest):
      suggestSym(c.graph, n.info, s, c.graph.usageSym, false)
    # field access (dot expr) will be handled by builtinFieldAccess
    if not isField:
      styleCheckUse(c, n.info, s)

proc semRoutineInTemplName(c: var TemplCtx, n: PNode): PNode =
  result = n
  if n.kind == nkIdent:
    let s = qualifiedLookUp(c.c, n, {})
    if s != nil:
      if s.owner == c.owner and (s.kind == skParam or sfGenSym in s.flags):
        incl(s.flags, sfUsed)
        result = newSymNode(s, n.info)
        onUse(n.info, s)
  else:
    for i in 0..<n.safeLen:
      result[i] = semRoutineInTemplName(c, n[i])

proc semRoutineInTemplBody(c: var TemplCtx, n: PNode, k: TSymKind): PNode =
  result = n
  checkSonsLen(n, bodyPos + 1, c.c.config)
  # routines default to 'inject':
  if n.kind notin nkLambdaKinds and symBinding(n[pragmasPos]) == spGenSym:
    let ident = getIdentNode(c, n[namePos])
    if not isTemplParam(c, ident):
      var s = newGenSym(k, ident, c)
      s.ast = n
      addPrelimDecl(c.c, s)
      styleCheckDef(c.c, n.info, s)
      onDef(n.info, s)
      n[namePos] = newSymNode(s, n[namePos].info)
    else:
      n[namePos] = ident
  else:
    n[namePos] = semRoutineInTemplName(c, n[namePos])
  # open scope for parameters
  openScope(c)
  for i in patternPos..paramsPos-1:
    n[i] = semTemplBody(c, n[i])

  if k == skTemplate: inc(c.inTemplateHeader)
  n[paramsPos] = semTemplBody(c, n[paramsPos])
  if k == skTemplate: dec(c.inTemplateHeader)

  for i in paramsPos+1..miscPos:
    n[i] = semTemplBody(c, n[i])
  # open scope for locals
  inc c.scopeN
  openScope(c)
  n[bodyPos] = semTemplBody(c, n[bodyPos])
  # close scope for locals
  closeScope(c)
  dec c.scopeN
  # close scope for parameters
  closeScope(c)

proc semTemplSomeDecl(c: var TemplCtx, n: PNode, symKind: TSymKind; start = 0) =
  for i in start..<n.len:
    var a = n[i]
    case a.kind:
    of nkCommentStmt: continue
    of nkIdentDefs, nkVarTuple, nkConstDef:
      checkMinSonsLen(a, 3, c.c.config)
      when defined(nimsuggest):
        inc c.c.inTypeContext
      a[^2] = semTemplBody(c, a[^2])
      when defined(nimsuggest):
        dec c.c.inTypeContext
      a[^1] = semTemplBody(c, a[^1])
      for j in 0..<a.len-2:
        addLocalDecl(c, a[j], symKind)
    else:
      illFormedAst(a, c.c.config)


proc semPattern(c: PContext, n: PNode; s: PSym): PNode

proc semTemplBodySons(c: var TemplCtx, n: PNode): PNode =
  result = n
  for i in 0..<n.len:
    result[i] = semTemplBody(c, n[i])

proc semTemplBody(c: var TemplCtx, n: PNode): PNode =
  result = n
  semIdeForTemplateOrGenericCheck(c.c.config, n, c.cursorInBody)
  case n.kind
  of nkIdent:
    if n.ident.id in c.toInject: return n
    let s = qualifiedLookUp(c.c, n, {})
    if s != nil:
      if s.owner == c.owner and s.kind == skParam and sfTemplateParam in s.flags:
        incl(s.flags, sfUsed)
        result = newSymNode(s, n.info)
        onUse(n.info, s)
      elif contains(c.toBind, s.id):
        result = symChoice(c.c, n, s, scClosed, c.noGenSym > 0)
      elif contains(c.toMixin, s.name.id):
        result = symChoice(c.c, n, s, scForceOpen, c.noGenSym > 0)
      elif s.owner == c.owner and sfGenSym in s.flags and c.noGenSym == 0:
        # template tmp[T](x: var seq[T]) =
        # var yz: T
        incl(s.flags, sfUsed)
        result = newSymNode(s, n.info)
        onUse(n.info, s)
      else:
        result = semTemplSymbol(c.c, n, s, c.noGenSym > 0)
  of nkBind:
    result = semTemplBody(c, n[0])
  of nkBindStmt:
    result = semBindStmt(c.c, n, c.toBind)
  of nkMixinStmt:
    if c.scopeN > 0: result = semTemplBodySons(c, n)
    else: result = semMixinStmt(c.c, n, c.toMixin)
  of nkEmpty, nkSym..nkNilLit, nkComesFrom:
    discard
  of nkIfStmt:
    for i in 0..<n.len:
      var it = n[i]
      if it.len == 2:
        openScope(c)
        it[0] = semTemplBody(c, it[0])
        it[1] = semTemplBody(c, it[1])
        closeScope(c)
      else:
        n[i] = semTemplBodyScope(c, it)
  of nkWhileStmt:
    openScope(c)
    for i in 0..<n.len:
      n[i] = semTemplBody(c, n[i])
    closeScope(c)
  of nkCaseStmt:
    openScope(c)
    n[0] = semTemplBody(c, n[0])
    for i in 1..<n.len:
      var a = n[i]
      checkMinSonsLen(a, 1, c.c.config)
      for j in 0..<a.len-1:
        a[j] = semTemplBody(c, a[j])
      a[^1] = semTemplBodyScope(c, a[^1])
    closeScope(c)
  of nkForStmt, nkParForStmt:
    openScope(c)
    n[^2] = semTemplBody(c, n[^2])
    for i in 0..<n.len - 2:
      if n[i].kind == nkVarTuple:
        for j in 0..<n[i].len-1:
          addLocalDecl(c, n[i][j], skForVar)
      else:
        addLocalDecl(c, n[i], skForVar)
    openScope(c)
    n[^1] = semTemplBody(c, n[^1])
    closeScope(c)
    closeScope(c)
  of nkBlockStmt, nkBlockExpr, nkBlockType:
    checkSonsLen(n, 2, c.c.config)
    openScope(c)
    if n[0].kind != nkEmpty:
      addLocalDecl(c, n[0], skLabel)
      when false:
        # labels are always 'gensym'ed:
        let s = newGenSym(skLabel, n[0], c)
        addPrelimDecl(c.c, s)
        styleCheckDef(c.c, s)
        onDef(n[0].info, s)
        n[0] = newSymNode(s, n[0].info)
    n[1] = semTemplBody(c, n[1])
    closeScope(c)
  of nkTryStmt, nkHiddenTryStmt:
    checkMinSonsLen(n, 2, c.c.config)
    n[0] = semTemplBodyScope(c, n[0])
    for i in 1..<n.len:
      var a = n[i]
      checkMinSonsLen(a, 1, c.c.config)
      openScope(c)
      for j in 0..<a.len-1:
        if a[j].isInfixAs():
          addLocalDecl(c, a[j][2], skLet)
          a[j][1] = semTemplBody(c, a[j][1])
        else:
          a[j] = semTemplBody(c, a[j])
      a[^1] = semTemplBodyScope(c, a[^1])
      closeScope(c)
  of nkVarSection: semTemplSomeDecl(c, n, skVar)
  of nkLetSection: semTemplSomeDecl(c, n, skLet)
  of nkFormalParams:
    checkMinSonsLen(n, 1, c.c.config)
    semTemplSomeDecl(c, n, skParam, 1)
    n[0] = semTemplBody(c, n[0])
  of nkConstSection: semTemplSomeDecl(c, n, skConst)
  of nkTypeSection:
    for i in 0..<n.len:
      var a = n[i]
      if a.kind == nkCommentStmt: continue
      if (a.kind != nkTypeDef): illFormedAst(a, c.c.config)
      checkSonsLen(a, 3, c.c.config)
      addLocalDecl(c, a[0], skType)
    for i in 0..<n.len:
      var a = n[i]
      if a.kind == nkCommentStmt: continue
      if (a.kind != nkTypeDef): illFormedAst(a, c.c.config)
      checkSonsLen(a, 3, c.c.config)
      if a[1].kind != nkEmpty:
        openScope(c)
        a[1] = semTemplBody(c, a[1])
        a[2] = semTemplBody(c, a[2])
        closeScope(c)
      else:
        a[2] = semTemplBody(c, a[2])
  of nkProcDef, nkLambdaKinds:
    result = semRoutineInTemplBody(c, n, skProc)
  of nkFuncDef:
    result = semRoutineInTemplBody(c, n, skFunc)
  of nkMethodDef:
    result = semRoutineInTemplBody(c, n, skMethod)
  of nkIteratorDef:
    result = semRoutineInTemplBody(c, n, skIterator)
  of nkTemplateDef:
    result = semRoutineInTemplBody(c, n, skTemplate)
  of nkMacroDef:
    result = semRoutineInTemplBody(c, n, skMacro)
  of nkConverterDef:
    result = semRoutineInTemplBody(c, n, skConverter)
  of nkPragmaExpr:
    result[0] = semTemplBody(c, n[0])
  of nkPostfix:
    result[1] = semTemplBody(c, n[1])
  of nkPragma:
    for x in n:
      if x.kind == nkExprColonExpr:
        x[1] = semTemplBody(c, x[1])
  of nkBracketExpr:
    result = newNodeI(nkCall, n.info)
    result.add newIdentNode(getIdent(c.c.cache, "[]"), n.info)
    for i in 0..<n.len: result.add(n[i])
    result = semTemplBodySons(c, result)
  of nkCurlyExpr:
    result = newNodeI(nkCall, n.info)
    result.add newIdentNode(getIdent(c.c.cache, "{}"), n.info)
    for i in 0..<n.len: result.add(n[i])
    result = semTemplBodySons(c, result)
  of nkAsgn, nkFastAsgn, nkSinkAsgn:
    checkSonsLen(n, 2, c.c.config)
    let a = n[0]
    let b = n[1]

    let k = a.kind
    case k
    of nkBracketExpr:
      result = newNodeI(nkCall, n.info)
      result.add newIdentNode(getIdent(c.c.cache, "[]="), n.info)
      for i in 0..<a.len: result.add(a[i])
      result.add(b)
      let a0 = semTemplBody(c, a[0])
      result = semTemplBodySons(c, result)
    of nkCurlyExpr:
      result = newNodeI(nkCall, n.info)
      result.add newIdentNode(getIdent(c.c.cache, "{}="), n.info)
      for i in 0..<a.len: result.add(a[i])
      result.add(b)
      result = semTemplBodySons(c, result)
    else:
      result = semTemplBodySons(c, n)
  of nkCallKinds-{nkPostfix}:
    # do not transform runnableExamples (bug #9143)
    if not isRunnableExamples(n[0]):
      result = semTemplBodySons(c, n)
  of nkDotExpr, nkAccQuoted:
    # dotExpr is ambiguous: note that we explicitly allow 'x.TemplateParam',
    # so we use the generic code for nkDotExpr too
    let s = qualifiedLookUp(c.c, n, {})
    if s != nil:
      # do not symchoice a quoted template parameter (bug #2390):
      if s.owner == c.owner and s.kind == skParam and
          n.kind == nkAccQuoted and n.len == 1:
        incl(s.flags, sfUsed)
        onUse(n.info, s)
        return newSymNode(s, n.info)
      elif contains(c.toBind, s.id):
        return symChoice(c.c, n, s, scClosed, c.noGenSym > 0)
      elif contains(c.toMixin, s.name.id):
        return symChoice(c.c, n, s, scForceOpen, c.noGenSym > 0)
      else:
        return symChoice(c.c, n, s, scOpen, c.noGenSym > 0)
    if n.kind == nkDotExpr:
      result = n
      result[0] = semTemplBody(c, n[0])
      inc c.noGenSym
      result[1] = semTemplBody(c, n[1])
      dec c.noGenSym
    else:
      result = semTemplBodySons(c, n)
  of nkExprColonExpr, nkExprEqExpr:
    if n.len == 2:
      inc c.noGenSym
      result[0] = semTemplBody(c, n[0])
      dec c.noGenSym
      result[1] = semTemplBody(c, n[1])
    else:
      result = semTemplBodySons(c, n)
  of nkTableConstr:
    # also transform the keys (bug #12595)
    for i in 0..<n.len:
      result[i] = semTemplBodySons(c, n[i])
  else:
    result = semTemplBodySons(c, n)

proc semTemplBodyDirty(c: var TemplCtx, n: PNode): PNode =
  result = n
  semIdeForTemplateOrGenericCheck(c.c.config, n, c.cursorInBody)
  case n.kind
  of nkIdent:
    let s = qualifiedLookUp(c.c, n, {})
    if s != nil:
      if s.owner == c.owner and s.kind == skParam:
        result = newSymNode(s, n.info)
      elif contains(c.toBind, s.id):
        result = symChoice(c.c, n, s, scClosed)
  of nkBind:
    result = semTemplBodyDirty(c, n[0])
  of nkBindStmt:
    result = semBindStmt(c.c, n, c.toBind)
  of nkEmpty, nkSym..nkNilLit, nkComesFrom:
    discard
  else:
    # dotExpr is ambiguous: note that we explicitly allow 'x.TemplateParam',
    # so we use the generic code for nkDotExpr too
    if n.kind == nkDotExpr or n.kind == nkAccQuoted:
      let s = qualifiedLookUp(c.c, n, {})
      if s != nil and contains(c.toBind, s.id):
        return symChoice(c.c, n, s, scClosed)
    result = n
    for i in 0..<n.len:
      result[i] = semTemplBodyDirty(c, n[i])

# in semstmts.nim:
proc semProcAnnotation(c: PContext, prc: PNode; validPragmas: TSpecialWords): PNode

proc semTemplateDef(c: PContext, n: PNode): PNode =
  result = semProcAnnotation(c, n, templatePragmas)
  if result != nil: return result
  result = n
  var s: PSym
  if isTopLevel(c):
    s = semIdentVis(c, skTemplate, n[namePos], {sfExported})
    incl(s.flags, sfGlobal)
  else:
    s = semIdentVis(c, skTemplate, n[namePos], {})
  assert s.kind == skTemplate

  styleCheckDef(c, s)
  onDef(n[namePos].info, s)
  # check parameter list:
  #s.scope = c.currentScope
  pushOwner(c, s)
  openScope(c)
  n[namePos] = newSymNode(s)
  pragmaCallable(c, s, n, templatePragmas)
  implicitPragmas(c, s, n.info, templatePragmas)

  setGenericParamsMisc(c, n)
  # process parameters:
  var allUntyped = true
  if n[paramsPos].kind != nkEmpty:
    semParamList(c, n[paramsPos], n[genericParamsPos], s)
    # a template's parameters are not gensym'ed even if that was originally the
    # case as we determine whether it's a template parameter in the template
    # body by the absence of the sfGenSym flag:
    for i in 1..<s.typ.n.len:
      let param = s.typ.n[i].sym
      param.flags.incl sfTemplateParam
      param.flags.excl sfGenSym
      if param.typ.kind != tyUntyped: allUntyped = false
  else:
    s.typ = newTypeS(tyProc, c)
    # XXX why do we need tyTyped as a return type again?
    s.typ.n = newNodeI(nkFormalParams, n.info)
    rawAddSon(s.typ, newTypeS(tyTyped, c))
    s.typ.n.add newNodeIT(nkType, n.info, s.typ[0])
  if n[genericParamsPos].safeLen == 0:
    # restore original generic type params as no explicit or implicit were found
    n[genericParamsPos] = n[miscPos][1]
    n[miscPos] = c.graph.emptyNode
  if allUntyped: incl(s.flags, sfAllUntyped)

  if n[patternPos].kind != nkEmpty:
    n[patternPos] = semPattern(c, n[patternPos], s)

  var ctx: TemplCtx
  ctx.toBind = initIntSet()
  ctx.toMixin = initIntSet()
  ctx.toInject = initIntSet()
  ctx.c = c
  ctx.owner = s
  if sfDirty in s.flags:
    n[bodyPos] = semTemplBodyDirty(ctx, n[bodyPos])
  else:
    n[bodyPos] = semTemplBody(ctx, n[bodyPos])
  # only parameters are resolved, no type checking is performed
  semIdeForTemplateOrGeneric(c, n[bodyPos], ctx.cursorInBody)
  closeScope(c)
  popOwner(c)

  # set the symbol AST after pragmas, at least. This stops pragma that have
  # been pushed (implicit) to be explicitly added to the template definition
  # and misapplied to the body. see #18113
  s.ast = n

  if sfCustomPragma in s.flags:
    if n[bodyPos].kind != nkEmpty:
      localError(c.config, n[bodyPos].info, errImplOfXNotAllowed % s.name.s)
  elif n[bodyPos].kind == nkEmpty:
    localError(c.config, n.info, "implementation of '$1' expected" % s.name.s)
  var (proto, comesFromShadowscope) = searchForProc(c, c.currentScope, s)
  if proto == nil:
    addInterfaceOverloadableSymAt(c, c.currentScope, s)
  elif not comesFromShadowscope:
    if {sfTemplateRedefinition, sfGenSym} * s.flags == {}:
      #wrongRedefinition(c, n.info, proto.name.s, proto.info)
      message(c.config, n.info, warnTemplateRedefinition, s.name.s)
    symTabReplace(c.currentScope.symbols, proto, s)
  if n[patternPos].kind != nkEmpty:
    c.patterns.add(s)

proc semPatternBody(c: var TemplCtx, n: PNode): PNode =
  template templToExpand(s: untyped): untyped =
    s.kind == skTemplate and (s.typ.len == 1 or sfAllUntyped in s.flags)

  proc newParam(c: var TemplCtx, n: PNode, s: PSym): PNode =
    # the param added in the current scope is actually wrong here for
    # macros because they have a shadowed param of type 'PNimNode' (see
    # semtypes.addParamOrResult). Within the pattern we have to ensure
    # to use the param with the proper type though:
    incl(s.flags, sfUsed)
    onUse(n.info, s)
    let x = c.owner.typ.n[s.position+1].sym
    assert x.name == s.name
    result = newSymNode(x, n.info)

  proc handleSym(c: var TemplCtx, n: PNode, s: PSym): PNode =
    result = n
    if s != nil:
      if s.owner == c.owner and s.kind == skParam:
        result = newParam(c, n, s)
      elif contains(c.toBind, s.id):
        result = symChoice(c.c, n, s, scClosed)
      elif templToExpand(s):
        result = semPatternBody(c, semTemplateExpr(c.c, n, s, {efNoSemCheck}))
      else:
        discard
        # we keep the ident unbound for matching instantiated symbols and
        # more flexibility

  proc expectParam(c: var TemplCtx, n: PNode): PNode =
    let s = qualifiedLookUp(c.c, n, {})
    if s != nil and s.owner == c.owner and s.kind == skParam:
      result = newParam(c, n, s)
    else:
      localError(c.c.config, n.info, "invalid expression")
      result = n

  result = n
  case n.kind
  of nkIdent:
    let s = qualifiedLookUp(c.c, n, {})
    result = handleSym(c, n, s)
  of nkBindStmt:
    result = semBindStmt(c.c, n, c.toBind)
  of nkEmpty, nkSym..nkNilLit: discard
  of nkCurlyExpr:
    # we support '(pattern){x}' to bind a subpattern to a parameter 'x';
    # '(pattern){|x}' does the same but the matches will be gathered in 'x'
    if n.len != 2:
      localError(c.c.config, n.info, "invalid expression")
    elif n[1].kind == nkIdent:
      n[0] = semPatternBody(c, n[0])
      n[1] = expectParam(c, n[1])
    elif n[1].kind == nkPrefix and n[1][0].kind == nkIdent:
      let opr = n[1][0]
      if opr.ident.s == "|":
        n[0] = semPatternBody(c, n[0])
        n[1][1] = expectParam(c, n[1][1])
      else:
        localError(c.c.config, n.info, "invalid expression")
    else:
      localError(c.c.config, n.info, "invalid expression")
  of nkStmtList, nkStmtListExpr:
    if stupidStmtListExpr(n):
      result = semPatternBody(c, n.lastSon)
    else:
      for i in 0..<n.len:
        result[i] = semPatternBody(c, n[i])
  of nkCallKinds:
    let s = qualifiedLookUp(c.c, n[0], {})
    if s != nil:
      if s.owner == c.owner and s.kind == skParam: discard
      elif contains(c.toBind, s.id): discard
      elif templToExpand(s):
        return semPatternBody(c, semTemplateExpr(c.c, n, s, {efNoSemCheck}))

    if n.kind == nkInfix and (let id = considerQuotedIdent(c.c, n[0]); id != nil):
      # we interpret `*` and `|` only as pattern operators if they occur in
      # infix notation, so that '`*`(a, b)' can be used for verbatim matching:
      if id.s == "*" or id.s == "**":
        result = newNodeI(nkPattern, n.info, n.len)
        result[0] = newIdentNode(id, n.info)
        result[1] = semPatternBody(c, n[1])
        result[2] = expectParam(c, n[2])
        return
      elif id.s == "|":
        result = newNodeI(nkPattern, n.info, n.len)
        result[0] = newIdentNode(id, n.info)
        result[1] = semPatternBody(c, n[1])
        result[2] = semPatternBody(c, n[2])
        return

    if n.kind == nkPrefix and (let id = considerQuotedIdent(c.c, n[0]); id != nil):
      if id.s == "~":
        result = newNodeI(nkPattern, n.info, n.len)
        result[0] = newIdentNode(id, n.info)
        result[1] = semPatternBody(c, n[1])
        return

    for i in 0..<n.len:
      result[i] = semPatternBody(c, n[i])
  else:
    # dotExpr is ambiguous: note that we explicitly allow 'x.TemplateParam',
    # so we use the generic code for nkDotExpr too
    case n.kind
    of nkDotExpr, nkAccQuoted:
      let s = qualifiedLookUp(c.c, n, {})
      if s != nil:
        if contains(c.toBind, s.id):
          return symChoice(c.c, n, s, scClosed)
        else:
          return newIdentNode(s.name, n.info)
    of nkPar:
      if n.len == 1: return semPatternBody(c, n[0])
    else: discard
    for i in 0..<n.len:
      result[i] = semPatternBody(c, n[i])

proc semPattern(c: PContext, n: PNode; s: PSym): PNode =
  openScope(c)
  var ctx: TemplCtx
  ctx.toBind = initIntSet()
  ctx.toMixin = initIntSet()
  ctx.toInject = initIntSet()
  ctx.c = c
  ctx.owner = getCurrOwner(c)
  result = flattenStmts(semPatternBody(ctx, n))
  if result.kind in {nkStmtList, nkStmtListExpr}:
    if result.len == 1:
      result = result[0]
    elif result.len == 0:
      localError(c.config, n.info, "a pattern cannot be empty")
  closeScope(c)
  addPattern(c, LazySym(sym: s))
