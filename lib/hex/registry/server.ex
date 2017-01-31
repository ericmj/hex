defmodule Hex.Registry.Server do
  use GenServer

  @behaviour Hex.Registry
  @compile {:parse_transform, :ms_transform}
  @name __MODULE__
  @filename "cache.ets"
  @timeout 60_000
  @update_interval 24 * 60 * 60

  # TODO: Bump version

  def start_link() do
    GenServer.start_link(__MODULE__, [], [name: @name])
  end

  def open(opts \\ []) do
    GenServer.call(@name, {:open, opts}, @timeout)
  end

  def close do
    GenServer.call(@name, :close, @timeout)
    |> print_update_message
  end

  def persist do
    GenServer.call(@name, :persist, @timeout)
    |> print_update_message
  end

  def check_update do
    GenServer.cast(@name, :check_update)
  end

  def prefetch(packages) do
    case GenServer.call(@name, {:prefetch, packages}, @timeout) do
      :ok ->
        :ok
      {:error, message} ->
        Mix.raise message
    end
  end

  def versions(repo, package) do
    GenServer.call(@name, {:versions, repo, package}, @timeout)
  end

  def deps(repo, package, version) do
    GenServer.call(@name, {:deps, repo, package, version}, @timeout)
  end

  def checksum(repo, package, version) do
    GenServer.call(@name, {:checksum, repo, package, version}, @timeout)
  end

  def retired(repo, package, version) do
    GenServer.call(@name, {:retired, repo, package, version}, @timeout)
  end

  def tarball_etag(repo, package, version) do
    GenServer.call(@name, {:tarball_etag, repo, package, version}, @timeout)
  end

  def tarball_etag(repo, package, version, etag) do
    GenServer.call(@name, {:tarball_etag, repo, package, version, etag}, @timeout)
  end

  defp print_update_message({:update, {:http_error, reason}}) do
    Hex.Shell.error "Hex update check failed, HTTP ERROR: #{inspect reason}"
    :ok
  end
  defp print_update_message({:update, {:status, status}}) do
    Hex.Shell.error "Hex update check failed, status code: #{status}"
    :ok
  end
  defp print_update_message({:update, version}) do
    Hex.Shell.warn "A new Hex version is available (#{Hex.version} < #{version}), " <>
                   "please update with `mix local.hex`"
    :ok
  end
  defp print_update_message(:ok), do: :ok

  def init([]) do
    {:ok, reset_state(%{})}
  end

  defp reset_state(state) do
    offline? = Hex.State.fetch!(:offline?)

    %{ets: nil,
      path: nil,
      pending: Hex.Set.new,
      fetched: Hex.Set.new,
      waiting: %{},
      waiting_close: nil,
      already_checked_update?: Map.get(state, :already_checked_update?, false),
      checking_update?: false,
      new_update: nil,
      offline?: offline?}
  end

  def handle_cast(:check_update, state) do
    state = check_update(state, force: true)
    {:noreply, state}
  end

  def handle_call({:open, opts}, _from, %{ets: nil} = state) do
    path = opts[:registry_path] || path()
    ets =
      Hex.string_to_charlist(path)
      |> open_ets
      |> check_version
      |> set_version
    state = %{state | ets: ets, path: path}
    state = check_update(state, force: false)
    {:reply, :ok, state}
  end
  def handle_call({:open, _opts}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:close, from, state) do
    maybe_wait_closing(state, from, fn
      %{ets: nil} = state ->
        state
      %{ets: tid, path: path} ->
        persist(tid, path)
        :ets.delete(tid)
        reset_state(state)
    end)
  end

  def handle_call(:persist, from, state) do
    maybe_wait_closing(state, from, fn %{ets: tid, path: path} = state ->
      persist(tid, path)
      state
    end)
  end

  def handle_call({:prefetch, packages}, _from, state) do
    packages =
      packages
      |> Enum.uniq
      |> Enum.reject(&(&1 in state.fetched))
      |> Enum.reject(&(&1 in state.pending))

    purge_repo_from_cache(packages, state)

    if Hex.State.fetch!(:offline?) do
      prefetch_offline(packages, state)
    else
      prefetch_online(packages, state)
    end
  end

  def handle_call({:versions, repo, package}, from, state) do
    maybe_wait({repo, package}, from, state, fn ->
      lookup(state.ets, {:versions, repo, package})
    end)
  end

  def handle_call({:deps, repo, package, version}, from, state) do
    maybe_wait({repo, package}, from, state, fn ->
      lookup(state.ets, {:deps, repo, package, version})
    end)
  end

  def handle_call({:checksum, repo, package, version}, from, state) do
    maybe_wait({repo, package}, from, state, fn ->
      lookup(state.ets, {:checksum, repo, package, version})
    end)
  end

  def handle_call({:retired, repo, package, version}, from, state) do
    maybe_wait({repo, package}, from, state, fn ->
      lookup(state.ets, {:retired, repo, package, version})
    end)
  end

  def handle_call({:tarball_etag, repo, package, version}, _from, state) do
    etag = lookup(state.ets, {:tarball_etag, repo, package, version})
    {:reply, etag, state}
  end

  def handle_call({:tarball_etag, repo, package, version, etag}, _from, state) do
    :ets.insert(state.ets, {{:tarball_etag, repo, package, version}, etag})
    {:reply, :ok, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({_ref, {:get_installs, result}}, state) do
    result =
      case result do
        {code, body, _headers} when code in 200..299 ->
          Hex.API.Registry.find_new_version_from_csv(body)
        {code, body, _} ->
          Hex.Shell.error("Failed to check for new Hex version")
          Hex.Utils.print_error_result(code, body)
          nil
      end

    :ets.insert(state.ets, {:last_update, :calendar.universal_time})
    state = reply_to_update_waiting(state, result)
    state = %{state | checking_update?: false}
    {:noreply, state}
  end

  def handle_info({:get_package, repo, package, result}, state) do
    repo_package = {repo, package}
    pending = Hex.Set.delete(state.pending, repo_package)
    fetched = Hex.Set.put(state.fetched, repo_package)
    {replys, waiting} = Map.pop(state.waiting, repo_package, [])

    write_result(result, repo, package, state)

    Enum.each(replys, fn {from, fun} ->
      GenServer.reply(from, fun.())
    end)

    state = %{state | pending: pending, waiting: waiting, fetched: fetched}
    {:noreply, state}
  end

  defp open_ets(path) do
    case :ets.file2tab(path) do
      {:ok, tid} ->
        tid
      {:error, {:read_error, {:file_error, _path, :enoent}}} ->
        :ets.new(@name, [])
      {:error, reason} ->
        Hex.Shell.error("Error opening ETS file #{path}: #{inspect reason}")
        File.rm(path)
        :ets.new(@name, [])
    end
  end

  defp check_version(ets) do
    case :ets.lookup(ets, :version) do
      [{:version, 1}] ->
        ets
      _ ->
        :ets.delete(ets)
        :ets.new(@name, [])
    end
  end

  defp set_version(ets) do
    :ets.insert(ets, {:version, 1})
    ets
  end

  defp persist(tid, path) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    :ok = :ets.tab2file(tid, Hex.to_charlist(path))
  end

  defp purge_repo_from_cache(packages, %{ets: ets}) do
    config = Hex.State.fetch!(:repos)

    Enum.each(packages, fn {repo, package} ->
      case Map.fetch(config, repo) do
        {:ok, %{url: url}} ->
          case :ets.lookup(ets, {:repo, repo}) do
            [{_key, ^url}] -> :ok
            [] -> :ok
            _ -> purge_repo(repo, ets)
          end
          :ets.insert(ets, {{:repo, repo}, url})
        :error ->
          throw {:norepo, repo, package}
      end
    end)
  catch
    :throw, {:norepo, repo, package} ->
      message = "Trying to use package #{package} from repo #{repo} without " <>
                "the repo being configured with `mix hex.repo`"
      {:error, message}
  end

  # fn
  #   {{:versions, ^repo, _package}, _} -> true
  #   {{:deps, ^repo, _package, _version}, _} -> true
  #   {{:checksum, ^repo, _package, _version}, _} -> true
  #   {{:retired, ^repo, _package, _version}, _} -> true
  #   {{:tarball_etag, ^repo, _package, _version}, _} -> true
  #   _ -> false
  # end
  defp purge_repo_matchspec(repo) do
    [{{{:versions, :"$1", :"$2"}, :_}, [{:"=:=", {:const, repo}, :"$1"}], [true]},
     {{{:deps, :"$1", :"$2", :"$3"}, :_}, [{:"=:=", {:const, repo}, :"$1"}], [true]},
     {{{:checksum, :"$1", :"$2", :"$3"}, :_}, [{:"=:=", {:const, repo}, :"$1"}], [true]},
     {{{:retired, :"$1", :"$2", :"$3"}, :_}, [{:"=:=", {:const, repo}, :"$1"}], [true]},
     {{{:tarball_etag, :"$1", :"$2", :"$3"}, :_}, [{:"=:=", {:const, repo}, :"$1"}], [true]},
     {:_, [], [false]}]
  end

  defp purge_repo(repo, ets) do
    :ets.select_delete(ets, purge_repo_matchspec(repo))
  end

  defp prefetch_online(packages, state) do
    Enum.each(packages, fn {repo, package} ->
      opts = fetch_opts(repo, package, state)
      Hex.Parallel.run(:hex_fetcher, {:registry, package}, [await: false], fn ->
        {:get_package, repo, package, Hex.API.Registry.get_package(repo, package, opts)}
      end)
    end)

    pending = Enum.into(packages, state.pending)
    state = %{state | pending: pending}
    {:reply, :ok, state}
  end

  defp prefetch_offline(packages, state) do
    missing =
      Enum.find(packages, fn {repo, package} ->
        unless lookup(state.ets, {:versions, repo, package}), do: package
      end)

    if missing do
      message = "Hex is running in offline mode and the registry entry for " <>
                "package #{inspect missing} is not cached locally"
      {:reply, {:error, message}, state}
    else
      fetched = Enum.into(packages, state.fetched)
      {:reply, :ok, %{state | fetched: fetched}}
    end
  end

  defp write_result({code, body, headers}, repo, package, %{ets: tid}) when code in 200..299 do
    releases =
      body
      |> :zlib.gunzip
      |> Hex.API.Registry.verify(repo)
      |> Hex.API.Registry.decode

    delete_package(repo, package, tid)

    Enum.each(releases, fn %{version: version, checksum: checksum, dependencies: deps} = release ->
      :ets.insert(tid, {{:checksum,repo,  package, version}, checksum})
      :ets.insert(tid, {{:retired, repo, package, version}, release[:retired]})
      deps = Enum.map(deps, fn dep ->
        {dep[:repository] || "hexpm",
         dep[:package],
         dep[:app] || dep[:package],
         dep[:requirement],
         !!dep[:optional]}
      end)
      :ets.insert(tid, {{:deps, repo, package, version}, deps})
    end)

    versions = Enum.map(releases, & &1[:version])
    :ets.insert(tid, {{:versions, repo, package}, versions})

    if etag = headers['etag'] do
      :ets.insert(tid, {{:registry_etag, repo, package}, List.to_string(etag)})
    end
  end
  defp write_result({304, _, _}, _repo, _package, _state) do
    :ok
  end
  defp write_result({404, _, _}, repo, package, %{ets: tid}) do
    delete_package(repo, package, tid)
    :ok
  end

  defp write_result({code, body, _}, _repo, package, %{ets: tid}) do
    cached? = !!:ets.lookup(tid, {:versions, package})
    cached_message = if cached?, do: " (using cache)"
    Hex.Shell.error("Failed to fetch record for '#{package}' from registry#{cached_message}")
    Hex.Utils.print_error_result(code, body)

    unless cached? do
      raise "Stopping due to errors"
    end
  end

  defp maybe_wait(package, from, state, fun) do
    cond do
      package in state.fetched ->
        {:reply, fun.(), state}
      package in state.pending ->
        tuple = {from, fun}
        waiting = Map.update(state.waiting, package, [tuple], &[tuple|&1])
        state = %{state | waiting: waiting}
        {:noreply, state}
      true ->
        raise "Package #{inspect package} not prefetched, please report this issue"
    end
  end

  defp fetch_opts(repo, package, %{ets: tid}) do
    case :ets.lookup(tid, {:registry_etag, repo, package}) do
      [{_, etag}] -> [etag: etag]
      [] -> []
    end
  end

  defp path do
    Path.join(Hex.State.fetch!(:home), @filename)
  end

  defp delete_package(repo, package, tid) do
    :ets.delete(tid, {:registry_etag, repo, package})
    versions = lookup(tid, {:versions, repo, package}) || []
    :ets.delete(tid, {:versions, repo, package})
    Enum.each(versions, fn version ->
      :ets.delete(tid, {:checksum, repo, package, version})
      :ets.delete(tid, {:retired, repo, package, version})
      :ets.delete(tid, {:deps, repo, package, version})
    end)
  end

  defp lookup(tid, key) do
    case :ets.lookup(tid, key) do
      [{^key, element}] -> element
      [] -> nil
    end
  end

  def maybe_wait_closing(%{checking_update?: true, new_update: nil} = state, from, fun) do
    state = %{state | waiting_close: {from, fun}}
    {:noreply, state}
  end
  def maybe_wait_closing(%{checking_update?: false, new_update: nil} = state, _from, fun) do
    {:reply, :ok, fun.(state)}
  end
  def maybe_wait_closing(%{checking_update?: false, new_update: new_update} = state, _from, fun) do
    state = %{state | new_update: nil}
    {:reply, {:update, new_update}, fun.(state)}
  end

  defp reply_to_update_waiting(state, new_update) do
    case state.waiting_close do
      {from, fun} ->
        reply = if new_update, do: {:update, new_update}, else: :ok
        state = fun.(state)
        GenServer.reply(from, reply)
        %{state | waiting_close: nil}
      nil ->
        %{state | new_update: new_update}
    end
  end

  defp check_update(%{already_checked_update?: true} = state, _opts) do
    state
  end
  defp check_update(%{checking_update?: true} = state, _opts) do
    state
  end
  defp check_update(%{offline?: true} = state, _opts) do
    state
  end
  defp check_update(%{ets: tid} = state, opts) do
    if opts[:force] || check_update?(tid) do
      Task.async(fn ->
        {:get_installs, Hex.API.Registry.get_installs}
      end)

      %{state | checking_update?: true, already_checked_update?: true}
    else
      state
    end
  end

  defp check_update?(tid) do
    if last = lookup(tid, :last_update) do
      now = :calendar.universal_time |> :calendar.datetime_to_gregorian_seconds
      last = :calendar.datetime_to_gregorian_seconds(last)

      now - last > @update_interval
    else
      true
    end
  end
end
