discard """
  matrix: "-d:nimPreviewRangeDefault --mm:refc; -d:nimPreviewRangeDefault --warningAsError:ProveInit --mm:orc"
  targets: "c cpp js"
"""

import times

type
  Guess = object
    poi: DateTime

  GuessDistinct = distinct Guess

block:
  var x: Guess
  discard Guess()

  var y: GuessDistinct

  discard y

  discard GuessDistinct(x)


import mobject_default_value

block:
  let x = Default()
  doAssert x.se == 0'i32
# echo Default(poi: 12)
# echo Default(poi: 17)

# echo NonDefault(poi: 77)

block:
  var x: Default
  doAssert x.se == 0'i32

type
  ObjectBase = object of RootObj
    value = 12

  ObjectBaseDistinct = distinct ObjectBase

  DinstinctInObject = object
    data: ObjectBaseDistinct

  Object = object of ObjectBase
    time: float = 1.2
    date: int
    scale: range[1..10]

  Object2 = object
    name: Object

  Object3 = object
    obj: Object2

  ObjectTuple = tuple
    base: ObjectBase
    typ: int
    obj: Object

  TupleInObject = object
    size = 777
    data: ObjectTuple

  Ref = ref object of ObjectBase

  RefInt = ref object of Ref
    data = 73

  Ref2 = ref object of ObjectBase

  RefInt2 = ref object of Ref
    data = 73

var t {.threadvar.}: Default
# var m1, m2 {.threadvar.}: Default

block:
  doAssert t.se == 0'i32

block: # ARC/ORC cannot bind destructors twice, so it cannot
      # be moved into main
  block:
    var x: Ref
    new(x)
    doAssert x.value == 12, "Ref.value = " & $x.value

    var y: RefInt
    new(y)
    doAssert y.value == 12
    doAssert y.data == 73

  block:
    var x: Ref2
    new(x, proc (x: Ref2) {.nimcall.} = discard "call Ref")
    doAssert x.value == 12, "Ref.value = " & $x.value

    proc call(x: RefInt2) =
      discard "call RefInt"

    var y: RefInt2
    new(y, call)
    doAssert y.value == 12
    doAssert y.data == 73

template main {.dirty.} =
  block: # bug #16744
    type
      R = range[1..10]
      Obj = object
        r: R

    var
      rVal: R = default(R) # Works fine
      objVal = default(Obj)

    doAssert rVal == 0 # it should be 1
    doAssert objVal.r == 1

  block: # bug #3608
    type
      abc = ref object
        w: range[2..100]

    proc createABC(): abc =
      new(result)
      result.w = 20

    doAssert createABC().w == 20

  block:
    var x = new ObjectBase
    doAssert x.value == 12

    proc hello(): ref ObjectBase =
      new result

    let z = hello()
    doAssert z.value == 12

  block:
    var base = ObjectBase()
    var x: ObjectBaseDistinct = ObjectBaseDistinct(base)
    doAssert ObjectBase(x).value == 12
    let y = ObjectBaseDistinct(default(ObjectBase))
    doAssert ObjectBase(y).value == 12

    proc hello(): ObjectBaseDistinct =
      result = ObjectBaseDistinct(default(ObjectBase))

    let z = hello()
    doAssert ObjectBase(z).value == 12

  block:
    var x: DinstinctInObject
    x.data = ObjectBaseDistinct(default(ObjectBase))

    doAssert ObjectBase(x.data).value == 12

  block:
    var x = Object()
    doAssert x.value == 12
    doAssert x.time == 1.2
    doAssert x.scale == 1

    let y = default(Object)
    doAssert y.value == 12
    doAssert y.time == 1.2
    doAssert y.scale == 1

    var x1, x2, x3 = default(Object)
    doAssert x1.value == 12
    doAssert x1.time == 1.2
    doAssert x1.scale == 1
    doAssert x2.value == 12
    doAssert x2.time == 1.2
    doAssert x2.scale == 1
    doAssert x3.value == 12
    doAssert x3.time == 1.2
    doAssert x3.scale == 1

  block:
    var x = new Object
    doAssert x[] == default(Object)

  block:
    var x = default(Object2)
    doAssert x.name.value == 12
    doAssert x.name.time == 1.2
    doAssert x.name.scale == 1

  block:
    var x: ref Object2
    new x
    doAssert x[] == default(Object2)

  block:
    var x = default(Object3) # todo Object3() ?
    doAssert x.obj.name.value == 12
    doAssert x.obj.name.time == 1.2
    doAssert x.obj.name.scale == 1

  when nimvm:
    discard "fixme"
  else:
    when defined(gcArc) or defined(gcOrc):
      block: #seq
        var x = newSeq[Object](10)
        let y = x[0]
        doAssert y.value == 12
        doAssert y.time == 1.2
        doAssert y.scale == 1

      block:
        var x: seq[Object]
        setLen(x, 5)
        let y = x[^1]
        doAssert y.value == 12
        doAssert y.time == 1.2
        doAssert y.scale == 1

  block: # array
    var x: array[10, Object] = arrayWith(default(Object), 10)
    let y = x[0]
    doAssert y.value == 12
    doAssert y.time == 1.2
    doAssert y.scale == 1

  block: # array
    var x {.noinit.}: array[10, Object]
    discard x

  block: # tuple
    var x = default(ObjectTuple)
    doAssert x.base.value == 12
    doAssert x.typ == 0
    doAssert x.obj.time == 1.2
    doAssert x.obj.date == 0
    doAssert x.obj.scale == 1
    doAssert x.obj.value == 12

  block: # tuple in object
    var x = default(TupleInObject)
    doAssert x.data.base.value == 12
    doAssert x.data.typ == 0
    doAssert x.data.obj.time == 1.2
    doAssert x.data.obj.date == 0
    doAssert x.data.obj.scale == 1
    doAssert x.data.obj.value == 12
    doAssert x.size == 777

  type
    ObjectArray = object
      data: array[10, Object]

  block:
    var x = default(ObjectArray)
    let y = x.data[0]
    doAssert y.value == 12
    doAssert y.time == 1.2
    doAssert y.scale == 1


  block:
    var x: PrellDeque[int]
    doAssert x.pendingTasks == 0

  type
    Color = enum
      Red, Blue, Yellow

    ObjectVarint = object
      case kind: Color
      of Red:
        data: int = 10
      of Blue:
        fill = "123"
      of Yellow:
        time = 1.8'f32

    ObjectVarint1 = object
      case kind: Color = Blue
      of Red:
        data1: int = 10
      of Blue:
        fill2 = "123"
        cry: float
      of Yellow:
        time3 = 1.8'f32
        him: int

  block:
    var x = ObjectVarint(kind: Red)
    doAssert x.kind == Red
    doAssert x.data == 10

  block:
    var x = ObjectVarint(kind: Blue)
    doAssert x.kind == Blue
    doAssert x.fill == "123"

  block:
    var x = ObjectVarint(kind: Yellow)
    doAssert x.kind == Yellow
    doAssert typeof(x.time) is float32

  block:
    var x = default(ObjectVarint1)
    doAssert x.kind == Blue
    doAssert x.fill2 == "123"
    x.cry = 326

  type
    ObjectVarint2 = object
      case kind: Color
      of Red:
        data: int = 10
      of Blue:
        fill = "123"
      of Yellow:
        time = 1.8'f32

  block:
    var x = ObjectVarint2(kind: Blue)
    doAssert x.fill == "123"

  block:
    type
      Color = enum
        Red, Blue, Yellow
  
    type
      ObjectVarint3 = object # fixme it doesn't work with static
        case kind: Color = Blue
        of Red:
          data1: int = 10
        of Blue:
          case name: Color = Blue
          of Blue:
            go = 12
          else:
            temp = 66
          fill2 = "123"
          cry: float
        of Yellow:
          time3 = 1.8'f32
          him: int

    block:
      var x = default(ObjectVarint3)
      doAssert x.kind == Blue
      doAssert x.name == Blue
      doAssert x.go == 12

    block:
      var x = ObjectVarint3(kind: Blue, name: Red, temp: 99)
      doAssert x.kind == Blue
      doAssert x.name == Red
      doAssert x.temp == 99

  block:
    type
      Default = tuple
        id: int = 1
        obj: ObjectBase
        name: string

      Class = object
        def: Default

      Member = object
        def: Default = (id: 777, obj: ObjectBase(), name: "fine")

    block:
      var x = default(Default)
      doAssert x.id == 1
      doAssert x.obj == default(ObjectBase)
      doAssert x.name == ""
    
    block:
      var x = default(Class)
      doAssert x.def == default(Default)
      doAssert x.def.id == 1
      doAssert x.def.obj == default(ObjectBase)
      doAssert x.def.name == ""

    when not defined(cpp):
      block:
        var x = default(Member)
        doAssert x.def.id == 777
        doAssert x.def.obj == default(ObjectBase)
        doAssert x.def.name == "fine"

  block:
    var x {.noinit.} = 12
    doAssert x == 12

    type
      Pure = object
        id: int = 12

    var y {.noinit.}: Pure
    doAssert y.id == 0

    var z {.noinit.}: Pure = Pure(id: 77)
    doAssert z.id == 77


proc main1 =
  var my = @[1, 2, 3, 4, 5]
  my.setLen(0)
  my.setLen(5)
  doAssert my == @[0, 0, 0, 0, 0]

proc main2 =
  var my = "hello"
  my.setLen(0)
  my.setLen(5)
  doAssert $(@my) == """@['\x00', '\x00', '\x00', '\x00', '\x00']"""

when defined(gcArc) or defined(gcOrc):
  main1()
  main2()

static: main()
main()
