defmodule Phoenix.LiveView.HTMLEngine do
  @moduledoc """
  The HTMLEngine that powers `.heex` templates and the `~H` sigil.

  It works by adding a HTML parsing and validation layer on top
  of EEx engine. By default it uses `Phoenix.LiveView.Engine` as
  its "subengine".
  """

  @doc """
  Renders a component defined by the given function.

  This function is rarely invoked directly by users. Instead, it is used by `~H`
  to render `Phoenix.Component`s. For example, the following:

      <MyApp.Weather.city name="Kraków" />

  Is the same as:

      <%= component(
            &MyApp.Weather.city/1,
            [name: "Kraków"],
            {__ENV__.module, __ENV__.function, __ENV__.file, __ENV__.line}
          ) %>

  """
  def component(func, assigns, caller)
      when (is_function(func, 1) and is_list(assigns)) or is_map(assigns) do
    assigns =
      case assigns do
        %{__changed__: _} -> assigns
        _ -> assigns |> Map.new() |> Map.put_new(:__changed__, nil)
      end

    case func.(assigns) do
      %Phoenix.LiveView.Rendered{} = rendered ->
        %{rendered | caller: caller}

      %Phoenix.LiveView.Component{} = component ->
        component

      other ->
        raise RuntimeError, """
        expected #{inspect(func)} to return a %Phoenix.LiveView.Rendered{} struct

        Ensure your render function uses ~H to define its template.

        Got:

            #{inspect(other)}

        """
    end
  end

  @doc """
  Define a inner block, generally used by slots.

  This macro is mostly used by HTML engines that provide
  a `slot` implementation and rarely called directly. The
  `name` must be the assign name the slot/block will be stored
  under.

  If you're using HEEx templates, you should use its higher
  level `<:slot>` notation instead. See `Phoenix.Component`
  for more information.
  """
  defmacro inner_block(name, do: do_block) do
    __inner_block__(do_block, name)
  end

  @doc false
  def __inner_block__([{:->, meta, _} | _] = do_block, key) do
    inner_fun = {:fn, meta, do_block}

    quote do
      fn parent_changed, arg ->
        var!(assigns) =
          unquote(__MODULE__).__assigns__(var!(assigns), unquote(key), parent_changed)

        _ = var!(assigns)
        unquote(inner_fun).(arg)
      end
    end
  end

  def __inner_block__(do_block, key) do
    quote do
      fn parent_changed, arg ->
        var!(assigns) =
          unquote(__MODULE__).__assigns__(var!(assigns), unquote(key), parent_changed)

        _ = var!(assigns)
        unquote(do_block)
      end
    end
  end

  @doc false
  def __assigns__(assigns, key, parent_changed) do
    # If the component is in its initial render (parent_changed == nil)
    # or the slot/block key is in parent_changed, then we render the
    # function with the assigns as is.
    #
    # Otherwise, we will set changed to an empty list, which is the same
    # as marking everything as not changed. This is correct because
    # parent_changed will always be marked as changed whenever any of the
    # assigns it references inside is changed. It will also be marked as
    # changed if it has any variable (such as the ones coming from let).
    if is_nil(parent_changed) or Map.has_key?(parent_changed, key) do
      assigns
    else
      Map.put(assigns, :__changed__, %{})
    end
  end

  alias Phoenix.LiveView.HTMLTokenizer
  alias Phoenix.LiveView.HTMLTokenizer.ParseError

  @behaviour Phoenix.Template.Engine

  @impl true
  def compile(path, _name) do
    # We need access for the caller, so we return a call to a macro.
    quote do
      require Phoenix.LiveView.HTMLEngine
      Phoenix.LiveView.HTMLEngine.compile(unquote(path))
    end
  end

  @doc false
  defmacro compile(path) do
    trim = Application.get_env(:phoenix, :trim_on_html_eex_engine, true)
    EEx.compile_file(path, engine: __MODULE__, line: 1, trim: trim, caller: __CALLER__)
  end

  @behaviour EEx.Engine

  @impl true
  def init(opts) do
    {subengine, opts} = Keyword.pop(opts, :subengine, Phoenix.LiveView.Engine)
    {module, opts} = Keyword.pop(opts, :module)

    unless subengine do
      raise ArgumentError, ":subengine is missing for HTMLEngine"
    end

    %{
      cont: :text,
      tokens: [],
      subengine: subengine,
      substate: subengine.init([]),
      module: module,
      file: Keyword.get(opts, :file, "nofile"),
      indentation: Keyword.get(opts, :indentation, 0),
      caller: Keyword.get(opts, :caller),
      previous_token_slot?: false
    }
  end

  ## These callbacks return AST

  @impl true
  def handle_body(%{tokens: tokens, file: file, cont: cont} = state) do
    tokens = HTMLTokenizer.finalize(tokens, file, cont)

    token_state =
      state
      |> token_state(nil)
      |> handle_tokens(tokens)
      |> validate_unclosed_tags!("template")

    opts = [root: token_state.root || false]
    ast = invoke_subengine(token_state, :handle_body, [opts])

    quote do
      require Phoenix.LiveView.HTMLEngine
      unquote(ast)
    end
  end

  defp validate_unclosed_tags!(%{tags: []} = state, _context) do
    state
  end

  defp validate_unclosed_tags!(%{tags: [tag | _]} = state, context) do
    {:tag_open, name, _attrs, %{line: line, column: column}} = tag
    file = state.file
    message = "end of #{context} reached without closing tag for <#{name}>"
    raise ParseError, line: line, column: column, file: file, description: message
  end

  @impl true
  def handle_end(state) do
    state
    |> token_state(false)
    |> handle_tokens(Enum.reverse(state.tokens))
    |> validate_unclosed_tags!("do-block")
    |> invoke_subengine(:handle_end, [])
  end

  defp token_state(
         %{subengine: subengine, substate: substate, file: file, module: module, caller: caller},
         root
       ) do
    %{
      subengine: subengine,
      substate: substate,
      file: file,
      stack: [],
      tags: [],
      slots: [],
      module: module,
      caller: caller,
      root: root,
      previous_token_slot?: false
    }
  end

  defp handle_tokens(token_state, tokens) do
    Enum.reduce(tokens, token_state, &handle_token/2)
  end

  ## These callbacks update the state

  @impl true
  def handle_begin(state) do
    update_subengine(%{state | tokens: []}, :handle_begin, [])
  end

  @impl true
  def handle_text(state, meta, text) do
    %{file: file, indentation: indentation, tokens: tokens, cont: cont} = state
    {tokens, cont} = HTMLTokenizer.tokenize(text, file, indentation, meta, tokens, cont)
    %{state | tokens: tokens, cont: cont}
  end

  @impl true
  def handle_expr(%{tokens: tokens} = state, marker, expr) do
    %{state | tokens: [{:expr, marker, expr} | tokens]}
  end

  ## Helpers

  defp push_substate_to_stack(%{substate: substate, stack: stack} = state) do
    %{state | stack: [{:substate, substate} | stack]}
  end

  defp pop_substate_from_stack(%{stack: [{:substate, substate} | stack]} = state) do
    %{state | stack: stack, substate: substate}
  end

  defp invoke_subengine(%{subengine: subengine, substate: substate}, fun, args) do
    apply(subengine, fun, [substate | args])
  end

  defp update_subengine(state, fun, args) do
    %{state | substate: invoke_subengine(state, fun, args), previous_token_slot?: false}
  end

  defp init_slots(state) do
    %{state | slots: [[] | state.slots]}
  end

  defp add_inner_block({roots?, attrs, locs}, ast, tag_meta) do
    {roots?, [{:inner_block, ast} | attrs], [line_column(tag_meta) | locs]}
  end

  defp add_slot!(
         %{slots: [slots | other_slots], tags: [{:tag_open, <<first, _::binary>>, _, _} | _]} =
           state,
         slot_name,
         slot_assigns,
         slot_info,
         tag_meta
       )
       when first in ?A..?Z or first == ?. do
    slot = {slot_name, slot_assigns, {tag_meta, slot_info}}
    %{state | slots: [[slot | slots] | other_slots], previous_token_slot?: true}
  end

  defp add_slot!(
         %{file: file} = _state,
         slot_name,
         _slot_assigns,
         _slot_info,
         %{line: line, column: column} = _tag_meta
       ) do
    message =
      "invalid slot entry <:#{slot_name}>. A slot entry must be a direct child of a component"

    raise ParseError, line: line, column: column, file: file, description: message
  end

  defp pop_slots(%{slots: [slots | other_slots]} = state) do
    # Perform group_by by hand as we need to group two distinct maps.
    {acc_assigns, acc_info} =
      Enum.reduce(slots, {%{}, %{}}, fn {key, assigns, info}, {acc_assigns, acc_info} ->
        case acc_assigns do
          %{^key => existing_assigns} ->
            acc_assigns = %{acc_assigns | key => [assigns | existing_assigns]}
            %{^key => existing_info} = acc_info
            acc_info = %{acc_info | key => [info | existing_info]}
            {acc_assigns, acc_info}

          %{} ->
            {Map.put(acc_assigns, key, [assigns]), Map.put(acc_info, key, [info])}
        end
      end)

    {Map.to_list(acc_assigns), Map.to_list(acc_info), %{state | slots: other_slots}}
  end

  defp push_tag(state, token) do
    # If we have a void tag, we don't actually push it into the stack.
    with {:tag_open, name, _attrs, _meta} <- token,
         true <- void?(name) do
      state
    else
      _ -> %{state | tags: [token | state.tags]}
    end
  end

  defp pop_tag!(
         %{tags: [{:tag_open, tag_name, _attrs, _meta} = tag | tags]} = state,
         {:tag_close, tag_name, _}
       ) do
    {tag, %{state | tags: tags}}
  end

  defp pop_tag!(
         %{tags: [{:tag_open, tag_open_name, _attrs, tag_open_meta} | _]} = state,
         {:tag_close, tag_close_name, tag_close_meta}
       ) do
    %{line: line, column: column} = tag_close_meta
    file = state.file

    message = """
    unmatched closing tag. Expected </#{tag_open_name}> for <#{tag_open_name}> \
    at line #{tag_open_meta.line}, got: </#{tag_close_name}>\
    """

    raise ParseError, line: line, column: column, file: file, description: message
  end

  defp pop_tag!(state, {:tag_close, tag_name, tag_meta}) do
    %{line: line, column: column} = tag_meta
    file = state.file
    message = "missing opening tag for </#{tag_name}>"
    raise ParseError, line: line, column: column, file: file, description: message
  end

  ## handle_token

  # Expr

  defp handle_token({:expr, marker, expr}, state) do
    state
    |> set_root_on_not_tag()
    |> update_subengine(:handle_expr, [marker, expr])
  end

  # Text

  defp handle_token({:text, text, %{line_end: line, column_end: column}}, state) do
    text = if state.previous_token_slot?, do: String.trim_leading(text), else: text

    if text == "" do
      state
    else
      state
      |> set_root_on_not_tag()
      |> update_subengine(:handle_text, [[line: line, column: column], text])
    end
  end

  # Remote function component (self close)

  defp handle_token(
         {:tag_open, <<first, _::binary>> = tag_name, attrs,
          %{self_close: true, line: line} = tag_meta},
         state
       )
       when first in ?A..?Z do
    attrs = remove_phx_no_break(attrs)
    file = state.file
    {mod_ast, fun} = decompose_remote_component_tag!(tag_name, tag_meta, file)
    {assigns, attr_info, state} = build_self_close_component_assigns(attrs, tag_meta.line, state)

    mod = Macro.expand(mod_ast, state.caller)
    store_component_call({mod, fun}, attr_info, [], line, state)

    ast =
      quote line: tag_meta.line do
        Phoenix.LiveView.HTMLEngine.component(
          &(unquote(mod_ast).unquote(fun) / 1),
          unquote(assigns),
          {__MODULE__, __ENV__.function, __ENV__.file, unquote(tag_meta.line)}
        )
      end

    state
    |> set_root_on_not_tag()
    |> update_subengine(:handle_expr, ["=", ast])
  end

  # Remote function component (with inner content)

  defp handle_token({:tag_open, <<first, _::binary>> = tag_name, attrs, tag_meta}, state)
       when first in ?A..?Z do
    mod_fun = decompose_remote_component_tag!(tag_name, tag_meta, state.file)
    token = {:tag_open, tag_name, attrs, Map.put(tag_meta, :mod_fun, mod_fun)}

    state
    |> set_root_on_not_tag()
    |> push_tag(token)
    |> init_slots()
    |> push_substate_to_stack()
    |> update_subengine(:handle_begin, [])
  end

  defp handle_token({:tag_close, <<first, _::binary>>, _tag_close_meta} = token, state)
       when first in ?A..?Z do
    {{:tag_open, _name, attrs, %{mod_fun: {mod_ast, fun}, line: line} = tag_meta}, state} =
      pop_tag!(state, token)

    mod = Macro.expand(mod_ast, state.caller)
    attrs = remove_phx_no_break(attrs)
    {assigns, attr_info, slot_info, state} = build_component_assigns(attrs, line, tag_meta, state)
    store_component_call({mod, fun}, attr_info, slot_info, line, state)

    ast =
      quote line: line do
        Phoenix.LiveView.HTMLEngine.component(
          &(unquote(mod_ast).unquote(fun) / 1),
          unquote(assigns),
          {__MODULE__, __ENV__.function, __ENV__.file, unquote(line)}
        )
      end

    state
    |> pop_substate_from_stack()
    |> update_subengine(:handle_expr, ["=", ast])
  end

  # Local function component (self close)

  defp handle_token(
         {:tag_open, "." <> name, attrs, %{self_close: true, line: line}},
         state
       ) do
    attrs = remove_phx_no_break(attrs)
    fun = String.to_atom(name)
    {assigns, attr_info, state} = build_self_close_component_assigns(attrs, line, state)

    mod = actual_component_module(state.caller, fun)
    store_component_call({mod, fun}, attr_info, [], line, state)

    ast =
      quote line: line do
        Phoenix.LiveView.HTMLEngine.component(
          &(unquote(Macro.var(fun, __MODULE__)) / 1),
          unquote(assigns),
          {__MODULE__, __ENV__.function, __ENV__.file, unquote(line)}
        )
      end

    state
    |> set_root_on_not_tag()
    |> update_subengine(:handle_expr, ["=", ast])
  end

  # Slot

  defp handle_token({:tag_open, ":inner_block", _attrs, meta}, state) do
    raise ParseError,
      line: meta.line,
      column: meta.column,
      file: state.file,
      description: "the slot name :inner_block is reserved"
  end

  # Slot (self close)

  defp handle_token({:tag_open, ":" <> slot_name, attrs, %{self_close: true} = tag_meta}, state) do
    attrs = remove_phx_no_break(attrs)
    %{line: line} = tag_meta
    slot_name = String.to_atom(slot_name)
    {let, roots, attrs, attr_info} = split_component_attrs(attrs, state.file)

    with {_, let_meta} <- let do
      raise ParseError,
        line: let_meta.line,
        column: let_meta.column,
        file: state.file,
        description: "cannot use :let on a slot without inner content"
    end

    attrs = [__slot__: slot_name, inner_block: nil] ++ attrs
    assigns = merge_component_attrs(roots, attrs, line)
    add_slot!(state, slot_name, assigns, attr_info, tag_meta)
  end

  # Slot (with inner content)

  defp handle_token({:tag_open, ":" <> _, _attrs, _tag_meta} = token, state) do
    state
    |> push_tag(token)
    |> push_substate_to_stack()
    |> update_subengine(:handle_begin, [])
  end

  defp handle_token({:tag_close, ":" <> slot_name, _tag_close_meta} = token, state) do
    {{:tag_open, _name, attrs, %{line: line} = tag_meta}, state} = pop_tag!(state, token)
    attrs = remove_phx_no_break(attrs)
    slot_name = String.to_atom(slot_name)

    {let, roots, attrs, attr_info} = split_component_attrs(attrs, state.file)
    clauses = build_component_clauses(let, state)

    ast =
      quote line: line do
        Phoenix.LiveView.HTMLEngine.inner_block(unquote(slot_name), do: unquote(clauses))
      end

    attrs = [__slot__: slot_name, inner_block: ast] ++ attrs
    assigns = merge_component_attrs(roots, attrs, line)

    state
    |> add_slot!(slot_name, assigns, add_inner_block(attr_info, ast, tag_meta), tag_meta)
    |> pop_substate_from_stack()
  end

  # Local function component (with inner content)

  defp handle_token({:tag_open, "." <> _, _attrs, _tag_meta} = token, state) do
    state
    |> set_root_on_not_tag()
    |> push_tag(token)
    |> init_slots()
    |> push_substate_to_stack()
    |> update_subengine(:handle_begin, [])
  end

  defp handle_token({:tag_close, "." <> fun_name, _tag_close_meta} = token, state) do
    {{:tag_open, _name, attrs, %{line: line} = tag_meta}, state} = pop_tag!(state, token)
    attrs = remove_phx_no_break(attrs)
    fun = String.to_atom(fun_name)
    mod = actual_component_module(state.caller, fun)

    {assigns, attr_info, slot_info, state} = build_component_assigns(attrs, line, tag_meta, state)
    store_component_call({mod, fun}, attr_info, slot_info, line, state)

    ast =
      quote line: line do
        Phoenix.LiveView.HTMLEngine.component(
          &(unquote(Macro.var(fun, __MODULE__)) / 1),
          unquote(assigns),
          {__MODULE__, __ENV__.function, __ENV__.file, unquote(line)}
        )
      end

    state
    |> pop_substate_from_stack()
    |> update_subengine(:handle_expr, ["=", ast])
  end

  # HTML element (self close)

  defp handle_token({:tag_open, name, attrs, %{self_close: true} = tag_meta}, state) do
    suffix = if void?(name), do: ">", else: "></#{name}>"
    attrs = remove_phx_no_break(attrs)
    validate_phx_attrs!(attrs, tag_meta, state)

    case pop_special_attr!(attrs, ":for", state) do
      {{":for", expr, _meta}, attrs} ->
        state
        |> update_subengine(:handle_begin, [])
        |> set_root_on_not_tag()
        |> handle_tag_and_attrs(name, attrs, suffix, to_location(tag_meta))
        |> handle_for_expr(expr, state)

      nil ->
        state
        |> set_root_on_tag()
        |> handle_tag_and_attrs(name, attrs, suffix, to_location(tag_meta))
    end
  end

  # HTML element

  defp handle_token({:tag_open, name, attrs, tag_meta} = token, state) do
    validate_phx_attrs!(attrs, tag_meta, state)
    attrs = remove_phx_no_break(attrs)

    case pop_special_attr!(attrs, ":for", state) do
      {{":for", expr, _meta}, attrs} ->
        state
        |> update_subengine(:handle_begin, [])
        |> set_root_on_not_tag()
        |> push_tag({:tag_open, name, attrs, Map.put(tag_meta, :for, {expr, state})})
        |> handle_tag_and_attrs(name, attrs, ">", to_location(tag_meta))

      nil ->
        state
        |> set_root_on_tag()
        |> push_tag(token)
        |> handle_tag_and_attrs(name, attrs, ">", to_location(tag_meta))
    end
  end

  defp handle_token({:tag_close, name, tag_meta} = token, state) do
    {{:tag_open, _name, _attrs, tag_open_meta}, state} = pop_tag!(state, token)
    state = update_subengine(state, :handle_text, [to_location(tag_meta), "</#{name}>"])

    case tag_open_meta[:for] do
      {expr, outer_state} ->
        handle_for_expr(state, expr, outer_state)

      nil ->
        state
    end
  end

  # Pop the given attr from attrs. Raises if the given attr is duplicated within
  # attrs.
  #
  # Examples:
  #
  #   attrs = [{":for", {...}}, {"class", {...}}]
  #   pop_special_attr!(state, attrs, ":for")
  #   => {{":for", {...}}, [{"class", {...}]}
  #
  #   attrs = [{"class", {...}}]
  #   pop_special_attr!(state, attrs, ":for")
  #   => nil
  defp pop_special_attr!(attrs, attr, state) do
    attrs
    |> List.keytake(attr, 0)
    |> raise_if_duplicated_special_attr!(state)
  end

  defp raise_if_duplicated_special_attr!({{attr, _expr, _meta}, attrs} = result, state) do
    case List.keytake(attrs, attr, 0) do
      {{attr, _expr, meta}, _attrs} ->
        message =
          "cannot define multiple #{inspect(attr)} attributes. Another #{inspect(attr)} has already been defined at line #{meta.line}"

        raise ParseError,
          line: meta.line,
          column: meta.column,
          file: state.file,
          description: message

      nil ->
        result
    end
  end

  defp raise_if_duplicated_special_attr!(nil, _state), do: nil

  # Root tracking
  defp set_root_on_not_tag(%{root: root, tags: tags} = state) do
    if tags == [] and root != false do
      %{state | root: false}
    else
      state
    end
  end

  defp set_root_on_tag(state) do
    case state do
      %{root: nil, tags: []} -> %{state | root: true}
      %{root: true, tags: []} -> %{state | root: false}
      %{root: bool} when is_boolean(bool) -> state
    end
  end

  ## handle_tag_and_attrs

  defp handle_tag_and_attrs(state, name, attrs, suffix, meta) do
    state
    |> update_subengine(:handle_text, [meta, "<#{name}"])
    |> handle_tag_attrs(meta, attrs)
    |> update_subengine(:handle_text, [meta, suffix])
  end

  defp handle_tag_attrs(state, meta, attrs) do
    Enum.reduce(attrs, state, fn
      {:root, {:expr, _, _} = expr, _attr_meta}, state ->
        handle_attrs_escape(state, meta, parse_expr!(expr, state))

      {name, {:expr, _, _} = expr, _attr_meta}, state ->
        handle_attr_escape(state, meta, name, parse_expr!(expr, state))

      {name, {:string, value, %{delimiter: ?"}}, _attr_meta}, state ->
        update_subengine(state, :handle_text, [meta, ~s( #{name}="#{value}")])

      {name, {:string, value, %{delimiter: ?'}}, _attr_meta}, state ->
        update_subengine(state, :handle_text, [meta, ~s( #{name}='#{value}')])

      {name, nil, _attr_meta}, state ->
        update_subengine(state, :handle_text, [meta, " #{name}"])
    end)
  end

  defp handle_for_expr(state, expr, outer_state) do
    expr = parse_expr!(expr, state)

    ast =
      quote do
        for unquote(expr), do: unquote(invoke_subengine(state, :handle_end, []))
      end

    update_subengine(outer_state, :handle_expr, ["=", ast])
  end

  defp parse_expr!({:expr, value, %{line: line, column: col}}, state) do
    Code.string_to_quoted!(value, line: line, column: col, file: state.file)
  end

  defp handle_attrs_escape(state, meta, attrs) do
    ast =
      quote line: meta[:line] do
        Phoenix.HTML.attributes_escape(unquote(attrs))
      end

    update_subengine(state, :handle_expr, ["=", ast])
  end

  defp handle_attr_escape(state, meta, name, value) do
    # See if we can emit anything about the attribute at compile-time.
    case extract_compile_attr(name, value) do
      :error ->
        # Now if the attribute can be encoded as empty whenever
        # it is false or nil, we also emit its text before hand.
        if call = empty_attribute_encoder(name, value, meta) do
          state
          |> update_subengine(:handle_text, [meta, ~s( #{name}=")])
          |> update_subengine(:handle_expr, ["=", {:safe, call}])
          |> update_subengine(:handle_text, [meta, ~s(")])
        else
          handle_attrs_escape(state, meta, [{safe_unless_special(name), value}])
        end

      parts ->
        state
        |> update_subengine(:handle_text, [meta, ~s( #{name}=")])
        |> handle_compile_attrs(meta, parts)
        |> update_subengine(:handle_text, [meta, ~s(")])
    end
  end

  defp handle_compile_attrs(state, meta, binaries) do
    binaries
    |> Enum.reverse()
    |> Enum.reduce(state, fn
      {:text, value}, state ->
        update_subengine(state, :handle_text, [meta, value])

      {:binary, value}, state ->
        ast =
          quote line: meta[:line] do
            {:safe, unquote(__MODULE__).binary_encode(unquote(value))}
          end

        update_subengine(state, :handle_expr, ["=", ast])

      {:class, value}, state ->
        ast =
          quote line: meta[:line] do
            {:safe, unquote(__MODULE__).class_attribute_encode(unquote(value))}
          end

        update_subengine(state, :handle_expr, ["=", ast])
    end)
  end

  defp extract_compile_attr("class", [head | tail]) when is_binary(head) do
    {bins, tail} = Enum.split_while(tail, &is_binary/1)
    encoded = class_attribute_encode([head | bins])

    if tail == [] do
      [{:text, IO.iodata_to_binary(encoded)}]
    else
      # We need to return it in reverse order as they are reversed later on.
      [{:class, tail}, {:text, IO.iodata_to_binary([encoded, ?\s])}]
    end
  end

  defp extract_compile_attr(_name, value) do
    extract_binaries(value, true, [])
  end

  defp extract_binaries({:<>, _, [left, right]}, _root?, acc) do
    extract_binaries(right, false, extract_binaries(left, false, acc))
  end

  defp extract_binaries({:<<>>, _, parts} = bin, _root?, acc) do
    Enum.reduce(parts, acc, fn
      part, acc when is_binary(part) ->
        [{:text, binary_encode(part)} | acc]

      {:"::", _, [binary, {:binary, _, _}]}, acc ->
        [{:binary, binary} | acc]

      _, _ ->
        throw(:unknown_part)
    end)
  catch
    :unknown_part -> [{:binary, bin} | acc]
  end

  defp extract_binaries(binary, _root?, acc) when is_binary(binary),
    do: [{:text, binary_encode(binary)} | acc]

  defp extract_binaries(value, false, acc),
    do: [{:binary, value} | acc]

  defp extract_binaries(_value, true, _acc),
    do: :error

  # TODO: We can refactor the empty_attribute_encoder to simply return an atom on Elixir v1.13+
  defp empty_attribute_encoder("class", value, meta) do
    quote line: meta[:line], do: unquote(__MODULE__).class_attribute_encode(unquote(value))
  end

  defp empty_attribute_encoder("style", value, meta) do
    quote line: meta[:line], do: unquote(__MODULE__).empty_attribute_encode(unquote(value))
  end

  defp empty_attribute_encoder(_, _, _), do: nil

  @doc false
  def class_attribute_encode(list) when is_list(list),
    do: list |> class_attribute_list() |> Phoenix.HTML.Engine.encode_to_iodata!()

  def class_attribute_encode(other),
    do: empty_attribute_encode(other)

  defp class_attribute_list(value) do
    value
    |> Enum.flat_map(fn
      nil -> []
      false -> []
      inner when is_list(inner) -> [class_attribute_list(inner)]
      other -> [other]
    end)
    |> Enum.join(" ")
  end

  @doc false
  def empty_attribute_encode(nil), do: ""
  def empty_attribute_encode(false), do: ""
  def empty_attribute_encode(true), do: ""
  def empty_attribute_encode(value), do: Phoenix.HTML.Engine.encode_to_iodata!(value)

  @doc false
  def binary_encode(value) when is_binary(value) do
    value
    |> Phoenix.HTML.Engine.encode_to_iodata!()
    |> IO.iodata_to_binary()
  end

  def binary_encode(value) do
    raise ArgumentError, "expected a binary in <>, got: #{inspect(value)}"
  end

  # We mark attributes as safe so we don't escape them
  # at rendering time. However, some attributes are
  # specially handled, so we keep them as strings shape.
  defp safe_unless_special("id"), do: :id
  defp safe_unless_special("aria"), do: :aria
  defp safe_unless_special("class"), do: :class
  defp safe_unless_special("data"), do: :data
  defp safe_unless_special(name), do: {:safe, name}

  ## build_self_close_component_assigns/build_component_assigns

  defp build_self_close_component_assigns(attrs, line, %{file: file} = state) do
    {let, roots, attrs, attr_info} = split_component_attrs(attrs, file)
    raise_if_let!(let, file)
    {merge_component_attrs(roots, attrs, line), attr_info, state}
  end

  defp build_component_assigns(attrs, line, tag_meta, %{file: file} = state) do
    {let, roots, attrs, attr_info} = split_component_attrs(attrs, file)
    clauses = build_component_clauses(let, state)

    inner_block =
      quote line: line do
        Phoenix.LiveView.HTMLEngine.inner_block(:inner_block, do: unquote(clauses))
      end

    inner_block_assigns =
      quote line: line do
        %{
          __slot__: :inner_block,
          inner_block: unquote(inner_block)
        }
      end

    {slot_assigns, slot_info, state} = pop_slots(state)

    slot_info = [
      {:inner_block, [{tag_meta, add_inner_block({false, [], []}, inner_block, tag_meta)}]}
      | slot_info
    ]

    attrs = attrs ++ [{:inner_block, [inner_block_assigns]} | slot_assigns]
    {merge_component_attrs(roots, attrs, line), attr_info, slot_info, state}
  end

  defp split_component_attrs(attrs, file) do
    {let, roots, attrs, locs} =
      attrs
      |> Enum.reverse()
      |> Enum.reduce({nil, [], [], []}, &split_component_attr(&1, &2, file))

    {let, roots, attrs, {roots != [], attrs, locs}}
  end

  defp split_component_attr(
         {:root, {:expr, value, %{line: line, column: col}}, _attr_meta},
         {let, r, a, locs},
         file
       ) do
    quoted_value = Code.string_to_quoted!(value, line: line, column: col, file: file)
    quoted_value = quote line: line, do: Map.new(unquote(quoted_value))
    {let, [quoted_value | r], a, locs}
  end

  # TODO: deprecate "let" in favor of `:let` on LV v0.19.
  defp split_component_attr(
         {let, {:expr, value, %{line: line, column: col} = meta}, _attr_meta},
         {nil, r, a, locs},
         file
       )
       when let in ["let", ":let"] do
    quoted_value = Code.string_to_quoted!(value, line: line, column: col, file: file)
    {{quoted_value, meta}, r, a, locs}
  end

  defp split_component_attr(
         {let, {:expr, _value, previous_meta}, _attr_meta},
         {{_, meta}, _, _, _},
         file
       )
       when let in ["let", ":let"] do
    message = """
    cannot define multiple :let attributes. \
    Another :let has already been defined at line #{previous_meta.line}\
    """

    raise ParseError,
      line: meta.line,
      column: meta.column,
      file: file,
      description: message
  end

  defp split_component_attr({":let", _, meta}, _state, file) do
    raise ParseError,
      line: meta.line,
      column: meta.column,
      file: file,
      description: ":let must be a pattern between {...}"
  end

  defp split_component_attr({":" <> _ = name, _, meta}, _state, file) do
    raise ParseError,
      line: meta.line,
      column: meta.column,
      file: file,
      description: "unsupported attribute #{inspect(name)} in component"
  end

  defp split_component_attr(
         {name, {:expr, value, %{line: line, column: col}}, attr_meta},
         {let, r, a, locs},
         file
       ) do
    quoted_value = Code.string_to_quoted!(value, line: line, column: col, file: file)
    {let, r, [{String.to_atom(name), quoted_value} | a], [line_column(attr_meta) | locs]}
  end

  defp split_component_attr(
         {name, {:string, value, _meta}, attr_meta},
         {let, r, a, locs},
         _file
       ) do
    {let, r, [{String.to_atom(name), value} | a], [line_column(attr_meta) | locs]}
  end

  defp split_component_attr({name, nil, attr_meta}, {let, r, a, locs}, _file) do
    {let, r, [{String.to_atom(name), true} | a], [line_column(attr_meta) | locs]}
  end

  defp line_column(%{line: line, column: column}), do: {line, column}

  defp merge_component_attrs(roots, attrs, line) do
    entries =
      case {roots, attrs} do
        {[], []} -> [{:%{}, [], []}]
        {_, []} -> roots
        {_, _} -> roots ++ [{:%{}, [], attrs}]
      end

    Enum.reduce(entries, fn expr, acc ->
      quote line: line, do: Map.merge(unquote(acc), unquote(expr))
    end)
  end

  defp decompose_remote_component_tag!(tag_name, tag_meta, file) do
    case String.split(tag_name, ".") |> Enum.reverse() do
      [<<first, _::binary>> = fun_name | rest] when first in ?a..?z ->
        aliases = rest |> Enum.reverse() |> Enum.map(&String.to_atom/1)
        fun = String.to_atom(fun_name)
        {{:__aliases__, [], aliases}, fun}

      _ ->
        %{line: line, column: column} = tag_meta
        message = "invalid tag <#{tag_name}>"
        raise ParseError, line: line, column: column, file: file, description: message
    end
  end

  @doc false
  def __unmatched_let__!(pattern, value) do
    message = """
    cannot match arguments sent from render_slot/2 against the pattern in :let.

    Expected a value matching `#{pattern}`, got: #{inspect(value)}\
    """

    stacktrace =
      self()
      |> Process.info(:current_stacktrace)
      |> elem(1)
      |> Enum.drop(2)

    reraise(message, stacktrace)
  end

  defp raise_if_let!(let, file) do
    with {_pattern, %{line: line}} <- let do
      message = "cannot use :let on a component without inner content"
      raise CompileError, line: line, file: file, description: message
    end
  end

  defp build_component_clauses(let, state) do
    case let do
      # If we have a var, we can skip the catch-all clause
      {{var, _, ctx} = pattern, %{line: line}} when is_atom(var) and is_atom(ctx) ->
        quote line: line do
          unquote(pattern) -> unquote(invoke_subengine(state, :handle_end, []))
        end

      {pattern, %{line: line}} ->
        quote line: line do
          unquote(pattern) -> unquote(invoke_subengine(state, :handle_end, []))
        end ++
          quote line: line, generated: true do
            other ->
              Phoenix.LiveView.HTMLEngine.__unmatched_let__!(
                unquote(Macro.to_string(pattern)),
                other
              )
          end

      _ ->
        quote do
          _ -> unquote(invoke_subengine(state, :handle_end, []))
        end
    end
  end

  defp store_component_call(component, attr_info, slot_info, line, %{module: module} = state) do
    if Module.open?(module) do
      pruned_slots =
        for {slot_name, slot_values} <- slot_info, into: %{} do
          values =
            for {tag_meta, {root?, attrs, locs}} <- slot_values do
              %{line: tag_meta.line, root: root?, attrs: attrs_for_call(attrs, locs)}
            end

          {slot_name, values}
        end

      {root?, attrs, locs} = attr_info
      pruned_attrs = attrs_for_call(attrs, locs)

      call = %{
        component: component,
        slots: pruned_slots,
        attrs: pruned_attrs,
        file: state.file,
        line: line,
        root: root?
      }

      Module.put_attribute(module, :__components_calls__, call)
    end
  end

  defp attrs_for_call(attrs, locs) do
    for {{attr, value}, {line, column}} <- Enum.zip(attrs, locs),
        do: {attr, {line, column, attr_type(value)}},
        into: %{}
  end

  defp attr_type({:<<>>, _, _} = value), do: {:string, value}
  defp attr_type(value) when is_list(value), do: {:list, value}
  defp attr_type(value) when is_binary(value), do: {:string, value}
  defp attr_type(value) when is_integer(value), do: {:integer, value}
  defp attr_type(value) when is_float(value), do: {:float, value}
  defp attr_type(value) when is_boolean(value), do: {:boolean, value}
  defp attr_type(value) when is_atom(value), do: {:atom, value}
  defp attr_type(_value), do: :any

  ## Helpers

  for void <- ~w(area base br col hr img input link meta param command keygen source) do
    defp void?(unquote(void)), do: true
  end

  defp void?(_), do: false

  defp to_location(%{line: line, column: column}), do: [line: line, column: column]

  defp actual_component_module(env, fun) do
    case lookup_import(env, {fun, 1}) do
      [{_, module} | _] -> module
      _ -> env.module
    end
  end

  # TODO: Use Macro.Env.lookup_import/2 when we require Elixir v1.13+
  defp lookup_import(%Macro.Env{functions: functions, macros: macros}, {name, arity} = pair)
       when is_atom(name) and is_integer(arity) do
    f = for {mod, pairs} <- functions, :ordsets.is_element(pair, pairs), do: {:function, mod}
    m = for {mod, pairs} <- macros, :ordsets.is_element(pair, pairs), do: {:macro, mod}
    f ++ m
  end

  defp remove_phx_no_break(attrs) do
    List.keydelete(attrs, "phx-no-format", 0)
  end

  # Check if `phx-update` or `phx-hook` is present in attrs and raises in case
  # there is no ID attribute set.
  defp validate_phx_attrs!(attrs, meta, state),
    do: validate_phx_attrs!(attrs, meta, state, nil, false)

  defp validate_phx_attrs!([], meta, state, attr, false)
       when attr in ["phx-update", "phx-hook"] do
    message = "attribute \"#{attr}\" requires the \"id\" attribute to be set"

    raise ParseError,
      line: meta.line,
      column: meta.column,
      file: state.file,
      description: message
  end

  defp validate_phx_attrs!([], _meta, _state, _attr, _id?), do: :ok

  # Handle <div phx-update="ignore" {@some_var}>Content</div> since here the ID
  # might be inserted dynamically so we can't raise at compile time.
  defp validate_phx_attrs!([{:root, _, _} | t], meta, state, attr, _id?),
    do: validate_phx_attrs!(t, meta, state, attr, true)

  defp validate_phx_attrs!([{"id", _, _} | t], meta, state, attr, _id?),
    do: validate_phx_attrs!(t, meta, state, attr, true)

  defp validate_phx_attrs!(
         [{"phx-update", {:string, value, _meta}, attr_meta} | t],
         meta,
         state,
         _attr,
         id?
       ) do
    if value in ~w(ignore append prepend replace) do
      validate_phx_attrs!(t, meta, state, "phx-update", id?)
    else
      message = "the value of the attribute \"phx-update\" must be: ignore, append or prepend"

      raise ParseError,
        line: attr_meta.line,
        column: attr_meta.column,
        file: state.file,
        description: message
    end
  end

  defp validate_phx_attrs!([{"phx-update", _attrs, _} | t], meta, state, _attr, id?) do
    validate_phx_attrs!(t, meta, state, "phx-update", id?)
  end

  defp validate_phx_attrs!([{"phx-hook", _, _} | t], meta, state, _attr, id?),
    do: validate_phx_attrs!(t, meta, state, "phx-hook", id?)

  @loop [":for"]

  defp validate_phx_attrs!([{loop, {:expr, _, _}, _} | t], meta, state, attr, id?)
       when loop in @loop,
       do: validate_phx_attrs!(t, meta, state, attr, id?)

  defp validate_phx_attrs!([{loop, _, attr_meta} | _], _meta, state, _attr, _id?)
       when loop in @loop do
    raise ParseError,
      line: attr_meta.line,
      column: attr_meta.column,
      file: state.file,
      description: "#{loop} must be a generator expresion between {...}"
  end

  defp validate_phx_attrs!([{":" <> _ = name, _, attr_meta} | _], _meta, state, _attr, _id?) do
    raise ParseError,
      line: attr_meta.line,
      column: attr_meta.column,
      file: state.file,
      description: "unsupported attribute #{inspect(name)} in tags"
  end

  defp validate_phx_attrs!([_h | t], meta, state, attr, id?),
    do: validate_phx_attrs!(t, meta, state, attr, id?)
end
