%% Convenience functions used to manipulate scope and its variables.
-module(elixir_scope).
-export([translate_var/4,
  build_erl_var/2, build_ex_var/2,
  load_binding/2, dump_binding/2,
  mergev/2, mergec/2, merge_clause_vars/2
]).
-include("elixir.hrl").

%% VAR HANDLING

translate_var(Meta, Name, Kind, S) when is_atom(Kind); is_integer(Kind) ->
  Line = ?line(Meta),
  Vars = S#elixir_scope.vars,
  Tuple = { Name, Kind },

  case S#elixir_scope.context of
    match ->
      MatchVars = S#elixir_scope.match_vars,
      case { orddict:is_key(Tuple, Vars), is_list(MatchVars) andalso ordsets:is_element(Tuple, MatchVars) } of
        { true, true } ->
          { { var, Line, orddict:fetch(Tuple, Vars) }, S };
        { Else, _ } ->
          { NewVar, NS } = if
            Kind /= nil -> build_erl_var(Line, S);
            Else -> build_erl_var(Line, Name, Name, S);
            S#elixir_scope.noname -> build_erl_var(Line, Name, Name, S);
            true -> { { var, Line, Name }, S }
          end,
          RealName = element(3, NewVar),
          ClauseVars = S#elixir_scope.clause_vars,
          { NewVar, NS#elixir_scope{
            vars=orddict:store(Tuple, RealName, Vars),
            match_vars=if
              MatchVars == nil -> MatchVars;
              true -> ordsets:add_element(Tuple, MatchVars)
            end,
            clause_vars=if
              ClauseVars == nil -> ClauseVars;
              true -> orddict:store(Tuple, RealName, ClauseVars)
            end
          } }
      end;
    _ ->
      { ok, VarName } = orddict:find({ Name, Kind }, Vars),
      { { var, Line, VarName }, S }
  end.

% Handle variables translation

build_ex_var(Line, S)  -> build_ex_var(Line, '', "_", S).
build_erl_var(Line, S) -> build_erl_var(Line, '', "_", S).

build_var_counter(Key, #elixir_scope{counter=Counter} = S) ->
  New = orddict:update_counter(Key, 1, Counter),
  { orddict:fetch(Key, New), S#elixir_scope{counter=New} }.

build_erl_var(Line, Key, Name, S) when is_integer(Line) ->
  { Counter, NS } = build_var_counter(Key, S),
  Var = { var, Line, ?atom_concat([Name, "@", Counter]) },
  { Var, NS }.

build_ex_var(Line, Key, Name, S) when is_integer(Line) ->
  { Counter, NS } = build_var_counter(Key, S),
  Var = { ?atom_concat([Name, "@", Counter]), [{line,Line}], nil },
  { Var, NS }.

%% SCOPE MERGING

%% Receives two scopes and return a new scope based on the second
%% with their variables merged.

mergev(S1, S2) ->
  V1 = S1#elixir_scope.vars,
  V2 = S2#elixir_scope.vars,
  C1 = S1#elixir_scope.clause_vars,
  C2 = S2#elixir_scope.clause_vars,
  S2#elixir_scope{
    vars=merge_vars(V1, V2),
    clause_vars=merge_clause_vars(C1, C2)
  }.

%% Receives two scopes and return the first scope with
%% counters and flags from the later.

mergec(S1, S2) ->
  S1#elixir_scope{
    counter=S2#elixir_scope.counter,
    extra_guards=S2#elixir_scope.extra_guards,
    super=S2#elixir_scope.super,
    caller=S2#elixir_scope.caller
  }.

% Merge variables trying to find the most recently created.

merge_vars(V, V) -> V;
merge_vars(V1, V2) ->
  orddict:merge(fun var_merger/3, V1, V2).

merge_clause_vars(nil, _C2) -> nil;
merge_clause_vars(_C1, nil) -> nil;
merge_clause_vars(C, C)     -> C;
merge_clause_vars(C1, C2)   ->
  orddict:merge(fun var_merger/3, C1, C2).

var_merger({ Var, _ }, Var, K2) -> K2;
var_merger({ Var, _ }, K1, Var) -> K1;
var_merger(_Var, K1, K2) ->
  V1 = var_number(atom_to_list(K1), []),
  V2 = var_number(atom_to_list(K2), []),
  case V1 > V2 of
    true  -> K1;
    false -> K2
  end.

var_number([$@|T], _Acc) -> var_number(T, []);
var_number([H|T], Acc)   -> var_number(T, [H|Acc]);
var_number([], Acc)      -> list_to_integer(lists:reverse(Acc)).

%% BINDINGS

load_binding(Binding, Scope) ->
  { NewBinding, NewVars, NewCounter } = load_binding(Binding, [], [], 0),
  { NewBinding, Scope#elixir_scope{
    vars=NewVars,
    match_vars=[],
    clause_vars=nil,
    counter=[{'',NewCounter}]
  } }.

load_binding([{Key,Value}|T], Binding, Vars, Counter) ->
  Actual = case Key of
    { _Name, _Kind } -> Key;
    Name when is_atom(Name) -> { Name, nil }
  end,
  InternalName = ?atom_concat(["_@", Counter]),
  load_binding(T,
    [{InternalName,Value}|Binding],
    orddict:store(Actual, InternalName, Vars), Counter + 1);
load_binding([], Binding, Vars, Counter) ->
  { lists:reverse(Binding), Vars, Counter }.

dump_binding(Binding, #elixir_scope{vars=Vars}) ->
  dump_binding(Vars, Binding, []).

dump_binding([{{Var,Kind}=Key,InternalName}|T], Binding, Acc) when is_atom(Kind) ->
  Actual = case Kind of
    nil -> Var;
    _   -> Key
  end,
  Value = proplists:get_value(InternalName, Binding, nil),
  dump_binding(T, Binding, orddict:store(Actual, Value, Acc));
dump_binding([_|T], Binding, Acc) ->
  dump_binding(T, Binding, Acc);
dump_binding([], _Binding, Acc) -> Acc.
