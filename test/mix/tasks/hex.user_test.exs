defmodule Mix.Tasks.Hex.UserTest do
  use HexTest.Case
  @moduletag :integration

  test "register" do
    send self(), {:mix_shell_input, :prompt, "eric"}
    send self(), {:mix_shell_input, :prompt, "mail@mail.com"}
    send self(), {:mix_shell_input, :yes?, false}
    send self(), {:mix_shell_input, :prompt, "hunter42"}
    send self(), {:mix_shell_input, :prompt, "hunter43"}

    assert_raise Mix.Error, "Entered passwords do not match", fn ->
      Mix.Tasks.Hex.User.run(["register"])
    end

    send self(), {:mix_shell_input, :prompt, "eric"}
    send self(), {:mix_shell_input, :prompt, "mail@mail.com"}
    send self(), {:mix_shell_input, :yes?, false}
    send self(), {:mix_shell_input, :prompt, "hunter42"}
    send self(), {:mix_shell_input, :prompt, "hunter42"}
    send self(), {:mix_shell_input, :prompt, "hunter43"}
    send self(), {:mix_shell_input, :prompt, "hunter43"}

    Mix.Tasks.Hex.User.run(["register"])

    assert {:ok, {200, body, _}} = Hex.API.User.get("eric")
    assert body["username"] == "eric"
  end

  test "auth" do
    in_tmp fn ->
      Hex.State.put(:home, System.cwd!)

      send self(), {:mix_shell_input, :prompt, "user"}
      send self(), {:mix_shell_input, :prompt, "hunter42"}
      send self(), {:mix_shell_input, :prompt, "hunter43"}
      send self(), {:mix_shell_input, :prompt, "hunter43"}
      Mix.Tasks.Hex.User.run(["auth"])

      {:ok, name} = :inet.gethostname()
      name = List.to_string(name)

      send self(), {:mix_shell_input, :prompt, "hunter43"}
      auth = Mix.Tasks.Hex.auth_info()
      assert {:ok, {200, body, _}} = Hex.API.Key.get(auth)
      assert name in Enum.map(body, &(&1["name"]))
    end
  end

  test "auth organizations" do
    in_tmp fn ->
      Hex.State.put(:home, System.cwd!)

      auth = Hexpm.new_user("userauthorg", "userauthorg@mail.com", "password", "userauthorg")
      Hexpm.new_repo("myuserauthorg", auth)

      send self(), {:mix_shell_input, :prompt, "userauthorg"}
      send self(), {:mix_shell_input, :prompt, "password"}
      send self(), {:mix_shell_input, :prompt, "password"}
      send self(), {:mix_shell_input, :prompt, "password"}
      Mix.Tasks.Hex.User.run(["auth"])

      assert {:ok, _} = Hex.Repo.fetch_repo("hexpm:myuserauthorg")
    end
  end

  test "deauth user and organizations" do
    in_tmp fn ->
      Hex.State.put(:home, System.cwd!)

      auth = Hexpm.new_user("userdeauth1", "userdeauth1@mail.com", "password", "userdeauth1")
      Hexpm.new_repo("myorguserdeauth1", auth)
      Mix.Tasks.Hex.update_key(auth[:encrypted_key])
      assert Hex.Config.read()[:encrypted_key] == auth[:encrypted_key]

      send self(), {:mix_shell_input, :prompt, "password"}
      Mix.Tasks.Hex.Organization.run(["auth", "myorguserdeauth1"])

      Mix.Tasks.Hex.User.run(["deauth"])
      refute Hex.Config.read()[:encrypted_key]
      refute Hex.Config.read()[:"$repos"]["hexpm:myorguserdeauth1"]
    end
  end

  test "deauth user but skip organizations" do
    in_tmp fn ->
      Hex.State.put(:home, System.cwd!)

      auth = Hexpm.new_user("userdeauth2", "userdeauth2@mail.com", "password", "userdeauth2")
      Hexpm.new_repo("myorguserdeauth2", auth)
      Mix.Tasks.Hex.update_key(auth[:encrypted_key])
      assert Hex.Config.read()[:encrypted_key] == auth[:encrypted_key]

      send self(), {:mix_shell_input, :prompt, "password"}
      Mix.Tasks.Hex.Organization.run(["auth", "myorguserdeauth2"])

      Mix.Tasks.Hex.User.run(["deauth", "--skip-organizations"])
      refute Hex.Config.read()[:encrypted_key]
      assert Hex.Config.read()[:"$repos"]["hexpm:myorguserdeauth2"]
    end
  end

  test "whoami" do
    in_tmp fn ->
      Hex.State.put(:home, System.cwd!)
      auth = Hexpm.new_user("whoami", "whoami@mail.com", "password", "whoami")
      Mix.Tasks.Hex.update_key(auth[:encrypted_key])

      send self(), {:mix_shell_input, :prompt, "password"}
      Mix.Tasks.Hex.User.run(["whoami"])
      assert_received {:mix_shell, :info, ["whoami"]}
    end
  end

  test "list keys" do
    in_tmp fn ->
      Hex.State.put(:home, System.cwd!)

      auth = Hexpm.new_user("list_keys", "list_keys@mail.com", "password", "list_keys")
      Mix.Tasks.Hex.update_key(auth[:encrypted_key])

      assert {:ok, {200, [%{"name" => "list_keys"}], _}} = Hex.API.Key.get(auth)

      send self(), {:mix_shell_input, :prompt, "password"}
      Mix.Tasks.Hex.User.run(["key", "--list"])
      assert_received {:mix_shell, :info, ["list_keys" <> _]}
    end
  end

  test "revoke key" do
    in_tmp fn ->
      Hex.State.put(:home, System.cwd!)

      auth_a = Hexpm.new_user("revoke_key", "revoke_key@mail.com", "password", "revoke_key_a")
      auth_b = Hexpm.new_key("revoke_key", "password", "revoke_key_b")
      Mix.Tasks.Hex.update_key(auth_a[:encrypted_key])

      assert {:ok, {200, _, _}} = Hex.API.Key.get(auth_a)
      assert {:ok, {200, _, _}} = Hex.API.Key.get(auth_b)

      send self(), {:mix_shell_input, :prompt, "password"}
      Mix.Tasks.Hex.User.run(["key", "--revoke", "revoke_key_b"])
      assert_received {:mix_shell, :info, ["Revoking key revoke_key_b..."]}

      assert {:ok, {200, _, _}} = Hex.API.Key.get(auth_a)
      assert {:ok, {401, _, _}} = Hex.API.Key.get(auth_b)

      send self(), {:mix_shell_input, :prompt, "password"}
      Mix.Tasks.Hex.User.run(["key", "--revoke", "revoke_key_a"])
      assert_received {:mix_shell, :info, ["Revoking key revoke_key_a..."]}
      assert_received {:mix_shell, :info, ["Authentication credentials removed from the local machine." <> _]}

      assert {:ok, {401, _, _}} = Hex.API.Key.get(auth_a)
    end
  end

  test "revoke all keys" do
    in_tmp fn ->
      Hex.State.put(:home, System.cwd!)

      auth_a = Hexpm.new_user("revoke_all_keys", "revoke_all_keys@mail.com", "password", "revoke_all_keys_a")
      auth_b = Hexpm.new_key("revoke_all_keys", "password", "revoke_all_keys_b")
      Mix.Tasks.Hex.update_key(auth_a[:encrypted_key])

      assert {:ok, {200, _, _}} = Hex.API.Key.get(auth_a)
      assert {:ok, {200, _, _}} = Hex.API.Key.get(auth_b)

      send self(), {:mix_shell_input, :prompt, "password"}
      Mix.Tasks.Hex.User.run(["key", "--revoke-all"])
      assert_received {:mix_shell, :info, ["Revoking all keys..."]}
      assert_received {:mix_shell, :info, ["Authentication credentials removed from the local machine." <> _]}

      assert {:ok, {401, _, _}} = Hex.API.Key.get(auth_a)
      assert {:ok, {401, _, _}} = Hex.API.Key.get(auth_b)
    end
  end

  test "reset account password" do
    Hexpm.new_user("reset_password", "reset_password@mail.com", "password", "reset_password")

    send self(), {:mix_shell_input, :prompt, "reset_password"}
    Mix.Tasks.Hex.User.run(["reset_password", "account"])

    assert_received {:mix_shell, :info, ["We’ve sent you an email" <> _]}
  end

  test "reset local password" do
    in_tmp fn ->
      Hex.State.put(:home, System.cwd!)

      Mix.Tasks.Hex.update_key(Mix.Tasks.Hex.encrypt_key("hunter42", "qwerty"))
      first_key = Hex.Config.read()[:encrypted_key]

      send self(), {:mix_shell_input, :prompt, "hunter42"}
      send self(), {:mix_shell_input, :prompt, "hunter43"}
      send self(), {:mix_shell_input, :prompt, "hunter43"}
      Mix.Tasks.Hex.User.run(["reset_password", "local"])

      assert Hex.Config.read()[:encrypted_key] != first_key

      send self(), {:mix_shell_input, :prompt, "wrong"}
      send self(), {:mix_shell_input, :prompt, "hunter43"}
      send self(), {:mix_shell_input, :prompt, "hunter44"}
      send self(), {:mix_shell_input, :prompt, "hunter44"}
      Mix.Tasks.Hex.User.run(["reset_password", "local"])
      assert_received {:mix_shell, :error, ["Wrong password. Try again"]}
    end
  end
end
