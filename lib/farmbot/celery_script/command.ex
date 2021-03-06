defmodule Farmbot.CeleryScript.Command do
  @moduledoc ~s"""
    Actionable CeleryScript Commands.
    There should be very little side affects here. just serial commands and
    ways to execute those serial commands.
    this means minimal logging, minimal bot state changeing (if its not the
    result of a gcode) etc.
  """
  alias   Farmbot.CeleryScript.{Ast, Error}
  alias   Farmbot.Database.Selectors
  alias   Farmbot.Context
  require Logger
  use     Farmbot.DebugLog

  celery =
    "lib/farmbot/celery_script/commands/"
    |> File.ls!
    |> Enum.reduce([], fn(file_name, acc) ->
      case String.split(file_name, ".ex") do
        [file_name, ""] ->
          mod = Module.concat Farmbot.CeleryScript.Command,
            Macro.camelize(file_name)
          [{String.to_atom(file_name), mod} | acc]
        _ -> acc
      end
    end)

  for {fun, module} <- celery do
    defdelegate unquote(fun)(args, body, context), to: module, as: :run
  end

  # DISCLAIMER:
  # PLEASE MAKE SURE EVERYTHING IS TYPESPECED AND DOC COMMENENTED IN HERE.
  # SOME NODES, ARE HARD TO TEST,
  # AND SOME NODES CAN CAUSE CATASTROPHIC DISASTERS
  # ALSO THE COMPILER CAN'T PROPERLY CHECK SOMETHING BEING THAT THE ARGS ARE
  # NOT POSITIONAL.

  @doc ~s"""
    Convert an ast node to a coodinate or return :error.
  """
  @spec ast_to_coord(Context.t, Ast.t) :: Context.t
  def ast_to_coord(context, ast)
  def ast_to_coord(
    %Context{} = context,
    %Ast{kind: "coordinate",
         args: %{x: _x, y: _y, z: _z},
         body: []} = already_done),
   do: Context.push_data(context, already_done)

  def ast_to_coord(
    %Context{} = context,
    %Ast{kind: "tool", args: %{tool_id: tool_id}, body: []})
  do
    %{body: ts}  = Farmbot.Database.Syncable.Point.get_tool(context, tool_id)
    point_map = %{
      x: ts.x,
      y: ts.y,
      z: ts.z
    }
    next_context = coordinate(point_map, [], context)
    raise_if_not_context_or_return_context("coordinate", next_context)
  end

  # is this one a good idea?
  # there might be two expectations here: it could return the current position,
  # or 0
  def ast_to_coord(%Context{} = context, %Ast{kind: "nothing", args: _, body: _}) do
    next_context = coordinate(%{x: 0, y: 0, z: 0}, [], context)
    raise_if_not_context_or_return_context("coordinate", next_context)
  end

  def ast_to_coord(%Context{} = context,
                   %Ast{kind: "point",
                        args: %{pointer_type: pt_t, pointer_id: pt_id},
                        body: _}) do
    %{body: p}   = Selectors.find_point(context, pt_t, pt_id)
    next_context = coordinate(%{x: p.x, y: p.y, z: p.z}, [], context)
    raise_if_not_context_or_return_context("coordinate", next_context)
  end

  def ast_to_coord(%Context{} = context, %Ast{} = ast) do
    raise Error, context: context,
      message: "No implicit conversion from #{inspect ast} " <>
        " to coordinate! context: #{inspect context}"
  end

  @doc """
    Converts celery script pairs to tuples
  """
  @spec pairs_to_tuples([Farmbot.CeleryScript.Command.Pair.t]) :: [tuple]
  def pairs_to_tuples(config_pairs) do
    Enum.map(config_pairs, fn(%Ast{} = thing) ->
      if thing.args.label == nil do
        Logger.info("Label was nil! #{inspect config_pairs}", type: :error)
      end
      {thing.args.label, thing.args.value}
    end)
  end

  defp maybe_print_comment(nil, _), do: :ok
  defp maybe_print_comment(comment, fun_name),
    do: Logger.info ">> [#{fun_name}] - #{comment}"

  @doc """
    Helper method to read pin or raise an error.
  """
  def read_pin_or_raise(%Context{} = ctx, number, pairs) do
    if Enum.find(pairs, fn(pair) ->
      match?(%Ast{kind: "pair", args: %{label: "eager_read_pin"}}, pair)
    end) do
      ast = %Ast{
        kind: "read_pin",
        args: %{label: "", pin_mode: 0, pin_number: String.to_integer(number)},
        body: []
      }
      do_command(ast, ctx)
    else
      raise Error, context: ctx,
        message: "Could not get value of pin #{number}. " <>
          "You should manually use read_pin block before this step."
    end
  end

  @doc """
    Makes sure serial is not unavailable.
  """
  def ensure_gcode({:error, reason}, %Context{} = context) do
    raise Error, context: context,
      message: "Could not execute gcode. #{inspect reason}"
  end

  def ensure_gcode(_, %Context{} = ctx), do: ctx

  @doc ~s"""
    Executes an ast tree.
  """
  @spec do_command(Ast.t, Context.t) :: Context.t | no_return
  def do_command(%Ast{} = ast, %Context{} = context) do
    try do
      do_execute_command(ast, context)
    rescue
      e in Farmbot.CeleryScript.Error ->
        Logger.error "Failed to execute CeleryScript: #{e.message}"
        reraise e, System.stacktrace()
      exception ->
        Logger.error "Unknown error happend executing CeleryScript."
        # debug_log "CeleryScript Error: #{inspect exception}"
        stacktrace = System.stacktrace()
        opts       = [custom: %{context: context}]
        ExRollbar.report(:error, exception, stacktrace, opts)
        reraise exception, stacktrace
    end
  end

  def do_command(not_cs_node, _) do
    raise Farmbot.CeleryScript.Error,
      message: "Can not handle: #{inspect not_cs_node}"
  end

  defp do_execute_command(%Ast{} = ast, %Context{} = context) do
    kind   = ast.kind
    module = Module.concat Farmbot.CeleryScript.Command, Macro.camelize(kind)
    if Code.ensure_loaded?(module) do
        maybe_print_comment(ast.comment, ast.kind)
        next_context = apply(module, :run, [ast.args, ast.body, context])
        raise_if_not_context_or_return_context(kind, next_context)
    else
      raise Farmbot.CeleryScript.Error, context: context,
        message: "No instruction for #{inspect ast}"
    end
  end

  defp raise_if_not_context_or_return_context(_, %Context{} = next), do: next
  defp raise_if_not_context_or_return_context(last_kind, not_context) do
    raise Farmbot.CeleryScript.Error,
      message: "[#{last_kind}] bad return value! #{inspect not_context}"
  end

  # behaviour
  @callback run(Ast.args, [Ast.t], Context.t) :: Context.t
end
