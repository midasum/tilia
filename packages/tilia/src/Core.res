module Reflect = {
  external has: ('a, string) => bool = "Reflect.has"
  external get: ('a, string) => 'b = "Reflect.get"
  external set: ('a, string, 'b) => bool = "Reflect.set"
  external ownKeys: 'a => 'b = "Reflect.ownKeys"
}

module Proxy = {
  @new external make: ('a, 'b) => 'c = "Proxy"
}
module Typeof = {
  external array: 'a => bool = "Array.isArray"
  let object: 'a => bool = %raw(`
    function(v) {
      return typeof v === 'object' && v !== null;
    }
  `)
}

type debug = {mutable c: int}
let d = {c: 0}

// Set of observers observing a given key in an object/array
type eyes = Set.t<Symbol.t>
// List of sets to which the the observer should add itself on flush
type collector = array<(dict<eyes>, string)>

type rec observer = {
  // The symbol that will be added to eyes on flush
  sym: Symbol.t,
  notify: unit => unit,
  // What this observer is observing (a list of eyes)
  collector: collector,
  // Where this observer is observing (used for clear and flush)
  root: root,
}
and root = {
  mutable collecting: option<collector>,
  observers: Map.t<Symbol.t, observer>,
}
type t<'a> = (root, 'a)
exception CoreBug(string)

let _connect = ((root, _), notify) => {
  let observer: observer = {
    sym: Symbol.make("obs"),
    notify,
    collector: [],
    root,
  }
  root.collecting = Some(observer.collector)
  observer
}

let _clear = (observer: observer) => {
  let {sym, root} = observer
  if Map.delete(root.observers, sym) {
    d.c = d.c - 1
    Array.forEach(observer.collector, ((observed, key)) => {
      switch Dict.get(observed, key) {
      | Some(eyes) =>
        if Set.delete(eyes, sym) {
          if Set.size(eyes) == 0 {
            ignore(Dict.delete(observed, key))
          }
        }
      | _ => ()
      }
    })
  }
}

let register = (sym: Symbol.t, leaf: (dict<eyes>, string)) => {
  let (observed, key) = leaf
  let eyes = switch Dict.get(observed, key) {
  | Some(eyes) => eyes
  | None => {
      let eyes = Set.make()
      Dict.set(observed, key, eyes)
      eyes
    }
  }
  Set.add(eyes, sym)
}

let _flush = (observer: observer) => {
  d.c = d.c + 1
  let {root, sym, collector} = observer
  switch root.collecting {
  | Some(c) if c == collector => root.collecting = None
  | _ => ()
  }
  Map.set(root.observers, sym, observer)
  Array.forEach(observer.collector, register(sym, ...))
}

// fixme, what should be used as unique key for these index methods ?
let indexKey = "::"

let ownKeys = (root: root, observed: dict<eyes>, target: 'a): 'b => {
  switch root.collecting {
  | Some(c) => Array.push(c, (observed, indexKey))
  | None => ()
  }
  Reflect.ownKeys(target)
}

let notify = (root, observed, key) => {
  switch Dict.get(observed, key) {
  | Some(eyes) => {
      Dict.delete(observed, key)
      Set.forEach(eyes, sym => {
        switch Map.get(root.observers, sym) {
        | Some(observer) => {
            _clear(observer)
            observer.notify()
          }
        | None => raise(CoreBug("Observing sym should always be in root.observers."))
        }
      })
    }
  | None => ()
  }
}

let rec get = (
  root: root,
  observed: dict<eyes>,
  proxied: dict<'c>,
  isArray: bool,
  target: 'a,
  key: string,
): 'b => {
  switch root.collecting {
  | Some(c) =>
    if isArray && key == "length" {
      Array.push(c, (observed, indexKey))
    } else {
      Array.push(c, (observed, key))
    }
  | None => ()
  }
  // is array and get length
  let v = Reflect.get(target, key)
  if Typeof.object(v) {
    switch Dict.get(proxied, key) {
    | Some(p) => p
    | None => {
        let p = proxify(root, v)
        Dict.set(proxied, key, p)
        p
      }
    }
  } else {
    v
  }
}

and set = (
  root: root,
  observed: dict<eyes>,
  proxied: dict<'c>,
  target: 'a,
  key: string,
  value: 'b,
) => {
  let hadKey = Reflect.has(target, key)
  let prev = Reflect.get(target, key)
  if prev == value {
    true
  } else {
    switch Reflect.set(target, key, value) {
    | false => false
    | true =>
      if Typeof.object(prev) {
        ignore(Dict.delete(proxied, key))
      }
      notify(root, observed, key)
      if !hadKey {
        // new key: trigger index
        notify(root, observed, indexKey)
      }
      true
    }
  }
}

and proxify = (root: root, target: 'a): 'a => {
  let observed: dict<eyes> = Dict.make()
  let proxied: dict<'b> = Dict.make()
  Proxy.make(
    target,
    {
      "set": set(root, observed, proxied, ...),
      "get": get(root, observed, proxied, Typeof.array(target), ...),
      "ownKeys": ownKeys(root, observed, ...),
    },
  )
}

let make = (seed: 'a): t<'a> => {
  let root = {
    collecting: None,
    observers: Map.make(),
  }
  (root, proxify(root, seed))
}

let observe = (t: t<'a>, callback: 'a => unit) => {
  let (_, p) = t
  let rec notify = () => {
    let o = _connect(t, notify)
    callback(p)
    _flush(o)
  }
  notify()
}
