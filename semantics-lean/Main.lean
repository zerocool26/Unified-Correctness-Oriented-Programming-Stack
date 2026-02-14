namespace Semantics

abbrev StateKey := String
abbrev ServiceName := String
abbrev MsgType := String

structure Message where
  fromService : ServiceName
  msgType : MsgType
  text : String
  deriving Repr, DecidableEq

abbrev Store := List (StateKey × Int)

def lookupState : Store -> StateKey -> Int
  | [], _ => 0
  | (k, v) :: xs, key => if k = key then v else lookupState xs key

def setState : Store -> StateKey -> Int -> Store
  | [], key, value => [(key, value)]
  | (k, v) :: xs, key, value =>
      if k = key then
        (key, value) :: xs
      else
        (k, v) :: setState xs key value

def incState (s : Store) (key : StateKey) (delta : Int := 1) : Store :=
  let current := lookupState s key
  setState s key (current + delta)

theorem lookup_set_eq (s : Store) (key : StateKey) (value : Int) :
    lookupState (setState s key value) key = value := by
  induction s with
  | nil =>
      simp [setState, lookupState]
  | cons hd tl ih =>
      cases hd with
      | mk k v =>
          by_cases h : k = key
          · simp [setState, lookupState, h]
          · simp [setState, lookupState, h, ih]

inductive Action where
  | log (template : String)
  | set (key : StateKey) (value : Int)
  | inc (key : StateKey) (delta : Int)
  | sendLocal (service : ServiceName) (msgType : MsgType) (template : String)
  | ifStateEq (key : StateKey) (value : Int) (thenAction : Action)
  deriving Repr, DecidableEq

structure ServiceState where
  store : Store
  outbox : List (ServiceName × Message)
  deriving Repr, DecidableEq

def emptyState : ServiceState :=
  { store := [], outbox := [] }

def enqueueLocal (st : ServiceState) (target : ServiceName) (msg : Message) : ServiceState :=
  { st with outbox := st.outbox ++ [(target, msg)] }

def applyAction
    (selfService : ServiceName)
    (incoming : Message)
    (action : Action)
    (st : ServiceState) : ServiceState :=
  match action with
  | Action.log _ => st
  | Action.set key value =>
      { st with store := setState st.store key value }
  | Action.inc key delta =>
      { st with store := incState st.store key delta }
  | Action.sendLocal target msgType template =>
      let msg : Message := {
        fromService := selfService,
        msgType := msgType,
        text := template
      }
      enqueueLocal st target msg
  | Action.ifStateEq key value thenAction =>
      if lookupState st.store key = value then
        applyAction selfService incoming thenAction st
      else
        st

def applyActions
    (selfService : ServiceName)
    (incoming : Message)
    (actions : List Action)
    (st : ServiceState) : ServiceState :=
  actions.foldl (fun acc act => applyAction selfService incoming act acc) st

theorem applyAction_deterministic
    (svc : ServiceName)
    (incoming : Message)
    (action : Action)
    (st : ServiceState) :
    applyAction svc incoming action st = applyAction svc incoming action st := rfl

theorem applyActions_deterministic
    (svc : ServiceName)
    (incoming : Message)
    (actions : List Action)
    (st : ServiceState) :
    applyActions svc incoming actions st = applyActions svc incoming actions st := rfl

end Semantics
