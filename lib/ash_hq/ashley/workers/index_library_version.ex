defmodule AshHq.Ashley.Workers.IndexLibraryVersion do
  require Ash.Query

  def index_all() do
    AshHq.Docs.Library.read!(load: :latest_version_id)
    |> Enum.each(&perform(&1.latest_version_id))
  end

  def perform(id) do
    pinecone_client = AshHq.Ashley.Pinecone.client()

    library_version = AshHq.Docs.get!(AshHq.Docs.LibraryVersion, id, load: :library)

    pinecone_client
    |> Pinecone.Vector.delete(%{
      filter: %{
        library: library_version.library.name
      }
    })

    guides(library_version)
    |> Stream.concat(modules(library_version))
    |> Stream.concat(functions(library_version))
    |> Stream.concat(dsls(library_version))
    |> Stream.concat(options(library_version))
    |> Stream.map(fn item ->
      {item, format(item, library_version)}
    end)
    |> Stream.chunk_every(100)
    |> Stream.map(fn batch ->
      case AshHq.Ashley.OpenAi.create_embeddings(Enum.map(batch, &elem(&1, 1))) do
        {:ok, %{"data" => data}} ->
          vectors =
            Enum.zip_with(data, batch, fn %{"embedding" => values}, {item, text} ->
              %{
                values: values,
                id: item.id,
                metadata: %{
                  library: library_version.library.name,
                  link: "#{path(item, library_version.library.name)}",
                  text: text
                }
              }
            end)

          Pinecone.Vector.upsert(pinecone_client, %{vectors: vectors})

        {:error, error} ->
          {:error, error}
      end
    end)
    |> Stream.run()
  end

  defp guides(library_version) do
    AshHq.Docs.Guide
    |> Ash.Query.filter(library_version_id == ^library_version.id)
    |> AshHq.Docs.stream()
  end

  defp modules(library_version) do
    AshHq.Docs.Module
    |> Ash.Query.filter(library_version_id == ^library_version.id)
    |> AshHq.Docs.stream()
  end

  defp functions(library_version) do
    AshHq.Docs.Function
    |> Ash.Query.filter(library_version_id == ^library_version.id)
    |> Ash.Query.load(:module_name)
    |> AshHq.Docs.stream()
  end

  defp dsls(library_version) do
    AshHq.Docs.Dsl
    |> Ash.Query.filter(library_version_id == ^library_version.id)
    |> Ash.Query.load(:extension_target)
    |> AshHq.Docs.stream()
  end

  defp options(library_version) do
    AshHq.Docs.Option
    |> Ash.Query.filter(library_version_id == ^library_version.id)
    |> Ash.Query.load(:extension_target)
    |> AshHq.Docs.stream()
  end

  defp path(%AshHq.Docs.Option{} = option, _library_name) do
    "docs/dsl/#{sanitize_name(option.extension_target)}##{String.replace(option.sanitized_path, "/", "-")}-#{sanitize_name(option.name)}"
  end

  defp path(%AshHq.Docs.Dsl{} = option, _library_name) do
    "docs/dsl/#{sanitize_name(option.extension_target)}##{String.replace(option.sanitized_path, "/", "-")}"
  end

  defp path(
         %AshHq.Docs.Function{
           sanitized_name: sanitized_name,
           arity: arity,
           type: type,
           module_name: module_name
         },
         library_name
       ) do
    "/docs/module/#{library_name}/latest/#{sanitize_name(module_name)}##{type}-#{sanitized_name}-#{arity}"
  end

  defp path(
         %AshHq.Docs.Module{
           sanitized_name: sanitized_name
         },
         library_name
       ) do
    "/docs/module/#{library_name}/latest/#{sanitized_name}"
  end

  defp path(
         %AshHq.Docs.Guide{
           route: route
         },
         library_name
       ) do
    "/docs/guides/#{library_name}/latest/#{route}"
  end

  defp format(%AshHq.Docs.Option{} = option, _library_version) do
    """
    DSL Entity: #{Enum.join(option.path ++ [option.name])}
    Default: #{option.default}
    #{option.doc}
    """
  end

  defp format(%AshHq.Docs.Dsl{type: :entity} = dsl, _library_version) do
    """
    DSL Entity: #{Enum.join(dsl.path ++ [dsl.name])}
    #{Enum.map_join(dsl.examples || [], &"```\n#{&1}\n```")}
    #{dsl.doc}
    """
  end

  defp format(%AshHq.Docs.Dsl{type: :section} = dsl, _library_version) do
    """
    DSL Section: #{Enum.join(dsl.path ++ [dsl.name])}
    #{Enum.map_join(dsl.examples || [], &"```\n#{&1}\n```")}
    #{dsl.doc}
    """
  end

  defp format(%AshHq.Docs.Function{} = function, _library_version) do
    """
    #{function.type} #{function.module_name}.#{function.name}/#{function.arity}
    #{Enum.join(function.heads, "\n")}
    #{function.doc}
    """
  end

  defp format(%AshHq.Docs.Module{} = module, _library_version) do
    """
    #{module.name}:
    #{module.doc}
    """
  end

  defp format(%AshHq.Docs.Guide{} = guide, _library_version) do
    """
    #{guide.name}:
    #{guide.text}
    """
  end

  def sanitize_name(name, allow_forward_slash? \\ false) do
    if allow_forward_slash? do
      String.downcase(String.replace(to_string(name), ~r/[^A-Za-z0-9\/_]/, "-"))
    else
      String.downcase(String.replace(to_string(name), ~r/[^A-Za-z0-9_]/, "-"))
    end
  end
end
