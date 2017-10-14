defmodule Mix.Tasks.Hex.BuildTest do
  use HexTest.Case
  @moduletag :integration

  defp package_created?(name) do
    File.exists?("#{name}.tar")
  end

  defp extract(name, path) do
    {:ok, files} = :hex_erl_tar.extract(name, [:memory])
    files = Enum.into(files, %{})
    :ok = :hex_erl_tar.extract({:binary, files['contents.tar.gz']}, [:compressed, cwd: path])
  end

  test "create" do
    Mix.Project.push ReleaseSimple.MixProject

    in_tmp fn ->
      Hex.State.put(:home, tmp_path())

      Mix.Tasks.Hex.Build.run([])
      assert package_created?("release_a-0.0.1")
    end
  after
    purge [ReleaseSimple.MixProject]
  end

  test "create with package name" do
    Mix.Project.push ReleaseName.MixProject

    in_tmp fn ->
      Hex.State.put(:home, tmp_path())

      Mix.Tasks.Hex.Build.run([])
      assert package_created?("released_name-0.0.1")
    end
  after
    purge [ReleaseName.MixProject]
  end

  test "create with files" do
    Mix.Project.push ReleaseFiles.MixProject

    in_tmp fn ->
      Hex.State.put(:home, tmp_path())
      File.write!("myfile.txt", "hello")
      File.write!("executable.sh", "world")
      File.chmod!("myfile.txt", 0o100644)
      File.chmod!("executable.sh", 0o100755)

      Mix.Tasks.Hex.Build.run([])

      extract("release_h-0.0.1.tar", "unzip")
      assert File.read!("unzip/myfile.txt") == "hello"
      assert File.stat!("unzip/myfile.txt").mode == 0o100644
      assert File.stat!("unzip/executable.sh").mode == 0o100755
    end
  after
    purge [ReleaseFiles.MixProject]
  end

  test "create with deps" do
    Mix.Project.push ReleaseDeps.MixProject

    in_tmp fn ->
      Hex.State.put(:home, tmp_path())

      Mix.Tasks.Deps.Get.run([])

      error_msg = "Stopping package build due to errors.\n" <>
                  "Missing metadata fields: maintainers, links"

      assert_raise Mix.Error, error_msg, fn ->
        Mix.Tasks.Hex.Build.run([])

        assert_received {:mix_shell, :error, ["No files"]}
        refute package_created?("release_b-0.0.2")
      end
    end
  after
    purge [ReleaseDeps.MixProject]
  end

  # TODO: convert to integration test
  test "create with custom repo deps" do
    Mix.Project.push ReleaseCustomRepoDeps.MixProject

    in_tmp fn ->
      Hex.State.put(:home, tmp_path())

      build = Mix.Tasks.Hex.Build.prepare_package()
      assert [
        %{name: "ex_doc", repository: "hexpm"},
        %{name: "ecto", repository: "my_repo"}
      ] = build.meta.requirements
    end
  after
    purge [ReleaseCustomRepoDeps.MixProject]
  end

  test "create with meta" do
    Mix.Project.push ReleaseMeta.MixProject

    in_tmp fn ->
      Hex.State.put(:home, tmp_path())

      error_msg = "Stopping package build due to errors.\n" <>
                  "Missing files: missing.txt, missing/*"

      assert_raise Mix.Error, error_msg, fn ->
        File.write!("myfile.txt", "hello")
        Mix.Tasks.Hex.Build.run([])

        assert_received {:mix_shell, :info, ["Building release_c 0.0.3"]}
        assert_received {:mix_shell, :info, ["  Files:"]}
        assert_received {:mix_shell, :info, ["    myfile.txt"]}
      end
    end
  after
    purge [ReleaseMeta.MixProject]
  end

  test "reject package if description is missing" do
    Mix.Project.push ReleaseNoDescription.MixProject

    in_tmp fn ->
      Hex.State.put(:home, tmp_path())

      error_msg = "Stopping package build due to errors.\n" <>
                  "Missing metadata fields: description, licenses, maintainers, links"

      assert_raise Mix.Error, error_msg, fn ->
        Mix.Tasks.Hex.Build.run([])

        assert_received {:mix_shell, :info, ["Building release_e 0.0.1"]}

        refute package_created?("release_e-0.0.1")
      end
    end
  after
    purge [ReleaseNoDescription.MixProject]
  end

  test "error if description is too long" do
    Mix.Project.push ReleaseTooLongDescription.MixProject

    in_tmp fn ->
      Hex.State.put(:home, tmp_path())

      error_msg = "Stopping package build due to errors.\n" <>
                  "Missing metadata fields: licenses, maintainers, links\n" <>
                  "Package description is very long (exceeds 300 characters)"

      assert_raise Mix.Error, error_msg, fn ->
        Mix.Tasks.Hex.Build.run([])
      end
    end
  after
    purge [ReleaseTooLongDescription.MixProject]
  end

  test "error if package has unstable dependencies" do
    Mix.Project.push ReleasePreDeps.MixProject

    in_tmp fn ->
      Hex.State.put(:home, tmp_path())

      error_msg = "A stable package release cannot have a pre-release dependency"

      assert_raise Mix.Error, error_msg, fn ->
        Mix.Tasks.Hex.Build.run([])
      end
    end
  after
    purge [ReleasePreDeps.MixProject]
  end

  test "error if misspelled organization" do
    Mix.Project.push ReleaseMisspelledOrganization.MixProject

    in_tmp fn ->
      Hex.State.put(:home, tmp_path())

      error_msg = "Invalid Hex package config :organisation, use spelling :organization"

      assert_raise Mix.Error, error_msg, fn ->
        Mix.Tasks.Hex.Build.run([])
      end
    end
  after
    purge [ReleaseMisspelledOrganization.MixProject]
  end

  test "warn if misplaced config" do
    Mix.Project.push ReleaseOrganizationWrongLocation.MixProject

    in_tmp fn ->
      Hex.State.put(:home, tmp_path())

      Mix.Tasks.Hex.Build.run([])
      assert_received {:mix_shell, :info, ["Building ecto 0.0.1"]}
      assert_received {:mix_shell, :info, ["\e[33mMix configuration :organization also belongs under the :package key, did you misplace it?\e[0m"]}
    end
  after
    purge [ReleaseOrganizationWrongLocation.MixProject]
  end

  test "error if hex_metadata.config is included" do
    Mix.Project.push ReleaseIncludeReservedFile.MixProject

    in_tmp fn ->
      Hex.State.put(:home, tmp_path())

      error_msg = "Stopping package build due to errors.\n" <>
                  "Do not include this file: hex_metadata.config"

      assert_raise Mix.Error, error_msg, fn ->
        File.write!("hex_metadata.config", "hello")
        Mix.Tasks.Hex.Build.run([])
      end
    end
  after
    purge [ReleaseIncludeReservedFile.MixProject]
  end

  test "error if smoke directory already exists" do
    Mix.Project.push(ReleaseIncludeRepoDeps.MixProject)

    in_tmp(fn ->
      Hex.State.put(:home, tmp_path())

      pkg_dir = "release_a-0.0.1-smoke"

      error_msg = "Please delete '#{pkg_dir}' if you want to continue. Exiting..."

      assert_raise(Mix.Error, error_msg, fn ->
        File.mkdir!(pkg_dir)
        Mix.Tasks.Hex.Build.run(["--smoke"])
      end)
    end)
  after
    purge([ReleaseIncludeRepoDeps.MixProject])
  end

  test "error if invalid option is given" do
    Mix.Project.push(ReleaseIncludeRepoDeps.MixProject)

    in_tmp(fn ->
      Hex.State.put(:home, tmp_path())

      error_msg = "1 error found!\n--invalid : Unknown option"

      assert_raise(OptionParser.ParseError, error_msg, fn ->
        Mix.Tasks.Hex.Build.run(["--invalid"])
      end)
    end)
  after
    purge([ReleaseIncludeRepoDeps.MixProject])
  end

  test "error if invalid argument is given" do
    Mix.Project.push(ReleaseIncludeRepoDeps.MixProject)

    in_tmp(fn ->
      Hex.State.put(:home, tmp_path())

      error_msg = "Invalid arguments, expected:\n\nmix hex.build [--smoke [command]...]\n"

      assert_raise(Mix.Error, error_msg, fn ->
        Mix.Tasks.Hex.Build.run(["echo hello"])
      end)
    end)
  after
    purge([ReleaseIncludeRepoDeps.MixProject])
  end

  test "create smoke package" do
    Mix.Project.push(ReleaseFiles.MixProject)

    in_tmp(fn ->
      Hex.State.put(:home, tmp_path())
      Mix.shell(Mix.Shell.IO)

      fun = fn ->
        File.write!("myfile.txt", "hello")
        File.write!("executable.sh", "world")
        assert Mix.Tasks.Hex.Build.run(["--smoke"]) == :ok
      end

      assert capture_io(fun) =~ "Building release_h 0.0.1"
    end)
  after
    Mix.shell(Mix.Shell.Process)
    purge([ReleaseFiles.MixProject])
  end

  test "create smoke package with extra commands" do
    Mix.Project.push(ReleaseFiles.MixProject)

    in_tmp(fn ->
      Hex.State.put(:home, tmp_path())
      Mix.shell(Mix.Shell.IO)

      fun = fn ->
        File.write!("myfile.txt", "hello")
        File.write!("executable.sh", "world")
        assert Mix.Tasks.Hex.Build.run(["--smoke", "touch end.txt"]) == :ok
      end

      assert capture_io(fun) =~ "Building release_h 0.0.1"
      assert File.exists?("release_h-0.0.1-smoke/contents/end.txt")
    end)
  after
    Mix.shell(Mix.Shell.Process)
    purge([ReleaseFiles.MixProject])
  end

  ## Helper
  defp capture_io(fun) do
    fun |> ExUnit.CaptureIO.capture_io() |> String.replace("\r\n", "\n")
  end
end
