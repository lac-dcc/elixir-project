defmodule Honey do
  alias Honey.Directories
  alias Honey.Boilerplates
  alias Honey.{Translator, Utils, Fuel, Optimizer}

  @moduledoc """
  Honey Potion is a framework that brings the powerful eBPF technology into Elixir.
  Users can write Elixir code that will be transformed into eBPF bytecodes.
  Many high-level features of Elixir are available and more will be added soon.
  In this alpha version, the framework translates the code to a subset of C that uses libbpf's features.
  Then it's possible to use clang to obtain the bytecodes and load it into the Kernel.
  """

  @doc """
  Makes sure the "use" keyword is inside a valid module to operate in and imports the modules that will be needed.
  """

  defmacro __using__(options) do
    with :error <- Keyword.fetch(options, :license) do
      raise "License is required when using the module Honey. Try 'use Honey, license: \"License type\"'."
    end

    if length(Module.get_attribute(__CALLER__.module, :before_compile)) != 0 do
      raise "Honey: Module #{__CALLER__.module} has already set the before_compile attribute."
    end

    Module.register_attribute(__CALLER__.module, :ebpf_maps, accumulate: true)

    quote do
      import Honey.Fuel
      import Honey
      @before_compile unquote(__MODULE__)
      @on_definition unquote(__MODULE__)
      @sections %{}
      @ebpf_options unquote(options)
    end
  end

  def __on_definition__(env, kind, fun, args, _guards, _body) do
    if sec = Module.get_attribute(env.module, :sec) do
      sections = Module.get_attribute(env.module, :sections)
      sections = Map.put(sections, {kind, fun, length(args)}, sec)
      Module.put_attribute(env.module, :sections, sections)
      Module.put_attribute(env.module, :sec, nil)
    end

    :ok
  end

  @doc """
  Writes c_code into a file in proj_path with module_name.
  This can use an optional clang_format with the last parameter.
  """

  def write_c_file(c_code, proj_path, module_name, clang_format) do
    "Elixir." <> module_name = "#{module_name}"

    c_path =
      proj_path
      |> Path.dirname()
      |> Path.join("src/#{module_name}.bpf.c")

    {:ok, file} = File.open(c_path, [:write])
    IO.binwrite(file, c_code)
    File.close(file)

    # Optional, format the file using clang-format:
    clang_format && System.cmd(clang_format, ["-i", c_path])

    true
  end

  @doc """
  Prepares a generic makefile in the directory of the user, writes a generic front-end for eBPF and compiles everything.
  This uses the LibBPF located in /benchmarks/libs/
  """

  def compile_eBPF(proj_path, module_name) do

    userdir = proj_path |> Path.dirname()

    makedir = Path.join(:code.priv_dir(:honey), "BPF_Boilerplates/Makefile")
    File.cp_r(makedir, userdir |> Path.join("Makefile"))

    mod_name = Atom.to_string(module_name)
    mod_name = String.slice(mod_name, 7, String.length(mod_name) - 7)

    frontend = Boilerplates.generate_frontend_code(mod_name)
    File.write(userdir |> Path.join("./src/#{mod_name}.c"), frontend)

    libsdir = __ENV__.file |> Path.dirname
    libsdir = Path.absname("./../benchmarks/libs/libbpf/src", libsdir) |> Path.expand

    System.cmd("make", ["TARGET := #{mod_name}", "LIBBPF_DIR := #{libsdir}"], cd: userdir)

  end

  @doc """
  Macro that allows users to define maps in eBPF through elixir.
  Users can define maps using the macro defmap. For example, to create a map named my_map, you can:

  ```
  defmap(:my_map,
      %{type: BPF_MAP_TYPE_ARRAY,
      max_entries: 10}
  )
  ```

  In the Alpha version, just the map type BPF_MAP_TYPE_ARRAY is available, but you only need to specify the number of entries and the map is ready to use.
  """

  defmacro defmap(ebpf_map_name, ebpf_map) do
    quote do
      ebpf_map_name = unquote(ebpf_map_name)
      ebpf_map_content = unquote(ebpf_map)
      @ebpf_maps %{name: ebpf_map_name, content: ebpf_map_content}
    end
  end

  @doc """
  Honey-Potion runs using the __before_compile__ macro. This macro starts up the execution.
  """

  defmacro __before_compile__(env) do
    target_func = :main
    target_arity = 1
    #If the main function isn't defined raise an error.
    if !(main_def = Module.get_definition(env.module, {target_func, target_arity})) do
      Utils.compile_error!(
        env,
        "Module #{env.module} is using Ebpf but does not contain #{target_func}/#{target_arity}."
      )
    end

    # TODO: evaluate all clauses
    {:v1, _kind, _metadata, [first_clause | _other_clauses]} = main_def
    {_metadata, arguments, _guards, func_ast} = first_clause
    #Burns Fuel (expands recursive calls into repetitions) and runs the optimizer on the AST.
    final_ast =
      func_ast
      |> Fuel.burn_fuel(env)
      # |> Optimizer.run()

    # print_ast(final_ast)

    ebpf_options = Module.get_attribute(env.module, :ebpf_options)
    #Gets values required to translate the AST to eBPF readable C.
    sections = Module.get_attribute(env.module, :sections)
    sec = Map.get(sections, {:def, target_func, target_arity})
    license = Keyword.fetch!(ebpf_options, :license)
    maps = Module.get_attribute(env.module, :ebpf_maps)
    # TODO: env.requires stores the requires in alphabetical order. This might be a problem.

    #Calls the code translator.
    c_code = Translator.translate("main", final_ast, sec, license, env.requires, maps)

    #Creates the directories for the file and compilation.
    Directories.create_all(env.file)

    #Writes the file.
    clang_format = Keyword.get(ebpf_options, :clang_format)
    write_c_file(c_code, env.file, env.module, clang_format)

    Module.delete_definition(env.module, {target_func, target_arity})

    #Does the compilation to an eBPF executable
    compile_eBPF(env.file, env.module)

    quote do
      def main(unquote(arguments)) do
        unquote(final_ast)
      end
    end
  end

  @doc false
  def print_ast(ast) do
    IO.puts("\nFinal code of main/1 after all fuel burned:")
    IO.puts(Macro.to_string(ast) <> "\n")
    IO.inspect(ast)
    IO.puts("")
  end
end
