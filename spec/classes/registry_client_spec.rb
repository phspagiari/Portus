require "rails_helper"

describe RegistryClient do
  let(:registry_server) { "registry.test.lan" }
  let(:username) { "flavio" }
  let(:password) { "this is a test" }

  it "handle ssl" do
    begin
      VCR.turned_off do
        WebMock.disable_net_connect!
        s = stub_request(:get, "https://#{registry_server}/v2/")
        registry = RegistryClient.new(registry_server)
        registry.perform_request("")
        expect(s).to have_been_requested
      end
    ensure
      WebMock.allow_net_connect!
    end
  end

  it "fails if the registry has authentication enabled and no credentials are set" do
    path = ""
    registry = RegistryClient.new(registry_server, false)
    VCR.use_cassette("registry/missing_credentials", record: :none) do
      expect do
        registry.perform_request(path)
      end.to raise_error(RegistryClient::CredentialsMissingError)
    end
  end

  context "authenticating with Registry server" do
    let(:path) { "" }

    it "can obtain an authentication token" do
      registry = RegistryClient.new(
        registry_server,
        false,
        username,
        password)

      VCR.use_cassette("registry/successful_authentication", record: :none) do
        res = registry.perform_request(path)
        expect(res).to be_a(Net::HTTPOK)
      end
    end

    it "raise an exception when the user credentials are wrong" do
      registry = RegistryClient.new(
        registry_server,
        false,
        username,
        "wrong password")

      VCR.use_cassette("registry/wrong_authentication", record: :none) do
        expect do
          registry.perform_request(path)
        end.to raise_error(RegistryClient::AuthorizationError)
      end
    end

    it "raises an AuthorizationError when the credentials are always wrong" do
      registry = RegistryClient.new(
        registry_server,
        false,
        username,
        password)

      begin
        VCR.turned_off do
          WebMock.disable_net_connect!
          auth = "service=foo,Bearer realm=http://bar.test.lan/token"
          url  = "http://flavio:this%20is%20a%20test@bar.test.lan/token?account=flavio&service=foo"

          stub_request(:get, "http://#{registry_server}/v2/")
            .to_return(headers: { "www-authenticate" => auth }, status: 401)

          stub_request(:get, url).to_return(status: 401)

          expect do
            registry.perform_request("")
          end.to raise_error(RegistryClient::AuthorizationError)
        end
      ensure
        WebMock.allow_net_connect!
      end
    end

    it "raises a NoBearerRealmException when the bearer realm is not found" do
      registry = RegistryClient.new(
        registry_server,
        false,
        username,
        password)

      begin
        VCR.turned_off do
          WebMock.disable_net_connect!
          stub_request(:get, "http://#{registry_server}/v2/")
            .to_return(headers: { "www-authenticate" => "foo=bar" }, status: 401)

          expect do
            registry.perform_request("")
          end.to raise_error(RegistryClient::NoBearerRealmException)
        end
      ensure
        WebMock.allow_net_connect!
      end
    end

    it "raises a NoBearerRealmException when the bearer realm is not found" do
      registry = RegistryClient.new(
        registry_server,
        false,
        username,
        password)

      begin
        VCR.turned_off do
          WebMock.disable_net_connect!
          stub_request(:get, "http://#{registry_server}/v2/")
            .to_return(headers: { "www-authenticate" => "foo=bar" }, status: 401)

          expect do
            registry.perform_request("")
          end.to raise_error(RegistryClient::NoBearerRealmException)
        end
      ensure
        WebMock.allow_net_connect!
      end
    end
  end

  context "fetching Image manifest" do
    let(:repository) { "foo/busybox" }
    let(:tag) { "1.0.0" }

    it "authenticates and fetches the image manifest" do
      VCR.use_cassette("registry/get_image_manifest", record: :none) do
        registry = RegistryClient.new(
          registry_server,
          false,
          username,
          password)

        manifest = registry.manifest(repository, tag)
        expect(manifest["name"]).to eq(repository)
        expect(manifest["tag"]).to eq(tag)
      end
    end

    it "fails if the image is not found" do
      VCR.use_cassette("registry/get_missing_image_manifest", record: :none) do
        registry = RegistryClient.new(
          registry_server,
          false,
          username,
          password)

        expect do
          registry.manifest(repository, "2.0.0")
        end.to raise_error(RegistryClient::NotFoundError)
      end
    end

    it "raises an exception when the return code is different from 200 or 401" do
      registry = RegistryClient.new(
        registry_server,
        false,
        username,
        password)
      tag = "2.0.0"

      begin
        VCR.turned_off do
          WebMock.disable_net_connect!
          stub_request(:get, "http://#{registry_server}/v2/#{repository}/manifests/#{tag}")
            .to_return(body: "BOOM", status: 500)

          expect do
            registry.manifest(repository, tag)
          end.to raise_error(RuntimeError)
        end
      ensure
        WebMock.allow_net_connect!
      end
    end
  end

  context "fetching Catalog from registry" do
    it "returns the available catalog" do
      create(:registry)
      create(:admin, username: "portus")

      VCR.use_cassette("registry/get_registry_catalog", record: :none) do
        registry = RegistryClient.new(
          registry_server,
          false,
          "portus",
          Rails.application.secrets.portus_password)

        catalog = registry.catalog
        expect(catalog.length).to be 1
        expect(catalog[0]["name"]).to eq "busybox"
        expect(catalog[0]["tags"]).to match_array(["latest"])
      end
    end

    it "fails if this version of registry does not implement /v2/_catalog" do
      VCR.use_cassette("registry/get_missing_catalog_endpoint", record: :none) do
        registry = RegistryClient.new(
          registry_server,
          false,
          username,
          password)

        expect do
          registry.catalog
        end.to raise_error(RegistryClient::NotFoundError)
      end
    end

    it "raises an exception when the return code is different from 200 or 401" do
      registry = RegistryClient.new(
        registry_server,
        false,
        username,
        password)

      begin
        VCR.turned_off do
          WebMock.disable_net_connect!
          stub_request(:get, "http://#{registry_server}/v2/_catalog")
            .to_return(body: "BOOM", status: 500)

          expect do
            registry.catalog
          end.to raise_error(RuntimeError)
        end
      ensure
        WebMock.allow_net_connect!
      end
    end
  end

  context "deleting a blob from an image" do
    it "deleting a blob that does not exist" do
      VCR.use_cassette("registry/delete_missing_blob", record: :none) do
        registry = RegistryClient.new(
          registry_server,
          false,
          "portus",
          Rails.application.secrets.portus_password)

        expect do
          registry.delete("busybox",
                          "sha256:a3ed95caeb02ffe68cdd9fd84406680ae93d633cb16422d00e8a7c22955b46d4")
        end.to raise_error(RegistryClient::NotFoundError, /BLOB_UNKNOWN/)
      end
    end

    it "deleting blobs is not enabled on the server" do
      VCR.use_cassette("registry/delete_disabled", record: :none) do
        registry = RegistryClient.new(
          registry_server,
          false,
          "portus",
          Rails.application.secrets.portus_password)

        expect do
          registry.delete("busybox",
                          "sha256:a3ed95caeb02ffe68cdd9fd84406680ae93d633cb16422d00e8a7c22955b46d4")
        end.to raise_error(RegistryClient::NotFoundError, /UNSUPPORTED/)
      end
    end

    it "allows the deletion of blobs" do
      VCR.use_cassette("registry/delete_blob", record: :none) do
        registry = RegistryClient.new(
          registry_server,
          false,
          "portus",
          Rails.application.secrets.portus_password)

        sha = "sha256:a3ed95caeb02ffe68cdd9fd84406680ae93d633cb16422d00e8a7c22955b46d4"
        res = registry.delete("busybox", sha)
        expect(res).to be true
      end
    end

    it "does what we expect on a Bad Request" do
      VCR.use_cassette("registry/invalid_delete_blob", record: :none) do
        registry = RegistryClient.new(
          registry_server,
          false,
          "portus",
          Rails.application.secrets.portus_password)

        expect do
          registry.delete("busybox",
                          "sha256:a3ed95caeb02ffe68cdd9fd84406680ae93d633cb16422d00e8a7c22955b46d4")
        end.to raise_error StandardError
      end
    end
  end
end
