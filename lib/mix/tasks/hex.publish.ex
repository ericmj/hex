defmodule Mix.Tasks.Hex.Publish do
  use Mix.Task
  alias Mix.Tasks.Hex.Build

  @shortdoc "Publishes a new package version"

  @moduledoc """
  Publishes a new version of your package and its documentation.

      mix hex.publish package

  If it is a new package being published it will be created and the user
  specified in `username` will be the package owner. Only package owners can
  publish.

  A published version can be amended or reverted with `--revert` up to one hour
  after its publication. Older packages can not be reverted.

      mix hex.publish docs

  The documentation will be accessible at `https://hexdocs.pm/my_package/1.0.0`,
  `https://hexdocs.pm/my_package` will always redirect to the latest published
  version.

  Documentation will be generated by running the `mix docs` task. `ex_doc`
  provides this task by default, but any library can be used. Or an alias can be
  used to extend the documentation generation. The expected result of the task
  is the generated documentation located in the `doc/` directory with an
  `index.html` file.

  Note that if you want to publish a new version of your package and its
  documentation in one step, you can use the following shorthand:

      mix hex.publish

  ## Command line options

    * `--revert VERSION` - Revert given version
    * `--organization ORGANIZATION` - The organization the package belongs to
    * `--no-confirm` - Disables confirmation message before publishing

  ## Configuration

    * `:app` - Package name (required).
    * `:version` - Package version (required).
    * `:deps` - List of package dependencies (see Dependencies below).
    * `:description` - Short description of the project.
    * `:package` - Hex specific configuration (see Package configuration below).

  ## Dependencies

  Dependencies are defined in mix's dependency format. But instead of using
  `:git` or `:path` as the SCM `:package` is used.

      defp deps() do
        [
          {:ecto, "~> 0.1.0"},
          {:postgrex, "~> 0.3.0"},
          {:cowboy, github: "extend/cowboy"}
        ]
      end

  As can be seen Hex package dependencies works alongside git dependencies.
  Important to note is that non-Hex dependencies will not be used during
  dependency resolution and neither will they be listed as dependencies of the
  package.

  ## Package configuration

  Additional metadata of the package can optionally be defined, but it is very
  recommended to do so.

    * `:name` - Set this if the package name is not the same as the application
      name.
    * `:organization` - Set this if you are publishing to an organization instead
      of the default public hex.pm.
    * `:files` - List of files and directories to include in the package,
      can include wildcards. Defaults to `["lib", "priv", "mix.exs", "README*",
      "readme*", "LICENSE*", "license*", "CHANGELOG*", "changelog*", "src"]`.
    * `:maintainers` - List of names and/or emails of maintainers.
    * `:licenses` - List of licenses used by the package.
    * `:links` - Map of links relevant to the package.
    * `:build_tools` - List of build tools that can build the package. Hex will
      try to automatically detect the build tools, it will do this based on the
      files in the package. If a "rebar" or "rebar.config" file is present Hex
      will mark it as able to build with rebar. This detection can be overridden
      by setting this field.
  """

  @switches [
    revert: :string,
    progress: :boolean,
    canonical: :string,
    organization: :string,
    organisation: :string,
    confirm: :boolean
  ]

  def run(args) do
    Hex.check_deps()
    Hex.start()
    {opts, args} = Hex.OptionParser.parse!(args, strict: @switches)

    build = Build.prepare_package()
    revert_version = opts[:revert]
    revert = !!revert_version
    organization = opts[:organization] || build.organization

    case args do
      ["package"] when revert ->
        auth = Mix.Tasks.Hex.auth_info(:write)
        revert_package(build, organization, revert_version, auth)

      ["docs"] when revert ->
        auth = Mix.Tasks.Hex.auth_info(:write)
        revert_docs(build, organization, revert_version, auth)

      [] when revert ->
        revert(build, organization, revert_version)

      ["package"] ->
        if proceed?(build, organization, opts) do
          auth = Mix.Tasks.Hex.auth_info(:write)
          create_release(build, organization, auth, opts)
        end

      ["docs"] ->
        docs_task(build, opts)
        auth = Mix.Tasks.Hex.auth_info(:write)
        create_docs(build, organization, auth, opts)

      [] ->
        create(build, organization, opts)

      _ ->
        Mix.raise("""
        Invalid arguments, expected one of:

        mix hex.publish
        mix hex.publish package
        mix hex.publish docs
        """)
    end
  end

  defp create(build, organization, opts) do
    if proceed?(build, organization, opts) do
      Hex.Shell.info("Building docs...")
      docs_task(build, opts)
      auth = Mix.Tasks.Hex.auth_info(:write)
      Hex.Shell.info("Publishing package...")

      if :ok == create_release(build, organization, auth, opts) do
        Hex.Shell.info("Publishing docs...")
        create_docs(build, organization, auth, opts)
      end
    end
  end

  defp create_docs(build, organization, auth, opts) do
    directory = docs_dir()
    name = build.meta.name
    version = build.meta.version

    unless File.exists?("#{directory}/index.html") do
      Mix.raise("File not found: #{directory}/index.html")
    end

    progress? = Keyword.get(opts, :progress, true)
    tarball = build_tarball(name, version, directory)
    send_tarball(organization, name, version, tarball, auth, progress?)
  end

  defp docs_task(build, opts) do
    name = build.meta.name
    canonical = opts[:canonical] || Hex.Utils.hexdocs_url(name)

    try do
      Mix.Task.run("docs", ["--canonical", canonical])
    rescue
      ex in [Mix.NoTaskError] ->
        stacktrace = System.stacktrace()

        Mix.shell().error("""
        Publication failed because the "docs" task is unavailable. You may resolve this by:

          1. Adding {:ex_doc, ">= 0.0.0", only: :dev} to your dependencies in your mix.exs and trying again
          2. If ex_doc was already added, make sure you run "mix hex.publish" in the same environment as the ex_doc package
          3. Publishing the package without docs by running "mix hex.publish package" (not recommended)
        """)

        reraise ex, stacktrace
    end
  end

  defp proceed?(build, organization, opts) do
    confirm? = Keyword.get(opts, :confirm, true)
    meta = build.meta
    exclude_deps = build.exclude_deps
    package = build.package

    Hex.Shell.info("Building #{meta.name} #{meta.version}")
    Build.print_info(meta, organization, exclude_deps, package[:files])

    print_link_to_coc()

    cond do
      not confirm? ->
        true

      organization in [nil, "hexpm"] ->
        Hex.Shell.info(["Publishing package to ", emphasis("public"), " repository hexpm."])
        Hex.Shell.yes?("Proceed?")

      true ->
        Hex.Shell.info([
          [
            "Publishing package to ",
            emphasis("private"),
            " repository #{organization}."
          ]
        ])

        Hex.Shell.yes?("Proceed?")
    end
  end

  defp emphasis(text) do
    if IO.ANSI.enabled?() do
      Hex.Shell.format([:bright, text, :reset])
    else
      ["**", text, "**"]
    end
  end

  defp print_link_to_coc() do
    Hex.Shell.info(
      "Before publishing, please read the Code of Conduct: " <>
        "https://hex.pm/policies/codeofconduct\n"
    )
  end

  defp revert(build, organization, version) do
    auth = Mix.Tasks.Hex.auth_info(:write)
    Hex.Shell.info("Reverting package...")
    revert_package(build, organization, version, auth)
    Hex.Shell.info("Reverting docs...")
    revert_docs(build, organization, version, auth)
  end

  defp revert_package(build, organization, version, auth) do
    version = Mix.Tasks.Hex.clean_version(version)
    name = build.meta.name

    case Hex.API.Release.delete(organization, name, version, auth) do
      {:ok, {code, _, _}} when code in 200..299 ->
        Hex.Shell.info("Reverted #{name} #{version}")

      other ->
        Hex.Shell.error("Reverting #{name} #{version} failed")
        Hex.Utils.print_error_result(other)
    end
  end

  defp revert_docs(build, organization, version, auth) do
    version = Mix.Tasks.Hex.clean_version(version)
    name = build.meta.name

    case Hex.API.ReleaseDocs.delete(organization, name, version, auth) do
      {:ok, {code, _, _}} when code in 200..299 ->
        Hex.Shell.info("Reverted docs for #{name} #{version}")

      other ->
        Hex.Shell.error("Reverting docs for #{name} #{version} failed")
        Hex.Utils.print_error_result(other)
    end
  end

  defp build_tarball(name, version, directory) do
    tarball = "#{name}-#{version}-docs.tar.gz"
    files = files(directory)
    :ok = :mix_hex_erl_tar.create(tarball, files, [:compressed])
    data = File.read!(tarball)

    File.rm!(tarball)
    data
  end

  defp send_tarball(organization, name, version, tarball, auth, progress?) do
    progress = progress_fun(progress?, byte_size(tarball))

    case Hex.API.ReleaseDocs.new(organization, name, version, tarball, auth, progress) do
      {:ok, {code, _, _}} when code in 200..299 ->
        Hex.Shell.info("")
        Hex.Shell.info("Docs published to #{Hex.Utils.hexdocs_url(name, version)}")
        :ok

      {:ok, {404, _, _}} ->
        Hex.Shell.info("")
        Hex.Shell.error("Publishing docs failed due to the package not being published yet")
        :error

      other ->
        Hex.Shell.info("")
        Hex.Shell.error("Publishing docs failed")
        Hex.Utils.print_error_result(other)
        :error
    end
  end

  defp files(directory) do
    "#{directory}/**"
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{relative_path(&1, directory), File.read!(&1)})
  end

  defp relative_path(file, dir) do
    Path.relative_to(file, dir)
    |> Hex.string_to_charlist()
  end

  defp docs_dir do
    cond do
      File.exists?("doc") ->
        "doc"

      File.exists?("docs") ->
        "docs"

      true ->
        Mix.raise(
          "Documentation could not be found. " <>
            "Please ensure documentation is in the doc/ or docs/ directory"
        )
    end
  end

  defp create_release(build, organization, auth, opts) do
    meta = build.meta
    {tarball, checksum} = Hex.create_tar!(meta, meta.files, :memory)
    progress? = Keyword.get(opts, :progress, true)
    progress = progress_fun(progress?, byte_size(tarball))

    case Hex.API.Release.new(organization, meta.name, tarball, auth, progress) do
      {:ok, {code, body, _}} when code in 200..299 ->
        location = body["html_url"] || body["url"]
        checksum = String.downcase(Base.encode16(checksum, case: :lower))
        Hex.Shell.info("")
        Hex.Shell.info("Package published to #{location} (#{checksum})")
        :ok

      other ->
        Hex.Shell.info("")
        Hex.Shell.error("Publishing failed")
        Hex.Utils.print_error_result(other)
        :error
    end
  end

  defp progress_fun(true, size), do: Mix.Tasks.Hex.progress(size)
  defp progress_fun(false, _size), do: Mix.Tasks.Hex.progress(nil)
end
