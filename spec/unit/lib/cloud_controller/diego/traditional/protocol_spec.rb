require 'spec_helper'

module VCAP::CloudController
  module Diego
    module Traditional
      describe Protocol do
        let(:blobstore_url_generator) do
          instance_double(CloudController::Blobstore::UrlGenerator,
            buildpack_cache_download_url: 'http://buildpack-artifacts-cache.com',
            app_package_download_url: 'http://app-package.com',
            perma_droplet_download_url: 'fake-droplet_uri',
            buildpack_cache_upload_url: 'http://buildpack-artifacts-cache.up.com',
            droplet_upload_url: 'http://droplet-upload-uri',
          )
        end

        let(:default_health_check_timeout) { 9999 }
        let(:staging_config) { TestConfig.config[:staging] }
        let(:common_protocol) { double(:common_protocol) }
        let(:app) { AppFactory.make }

        subject(:protocol) do
          Protocol.new(blobstore_url_generator, common_protocol)
        end

        before do
          allow(common_protocol).to receive(:staging_egress_rules).and_return(['staging_egress_rule'])
          allow(common_protocol).to receive(:running_egress_rules).with(app).and_return(['running_egress_rule'])
        end

        describe '#stage_app_request' do
          let(:request) { protocol.stage_app_request(app, staging_config) }

          it 'returns arguments intended for CfMessageBus::MessageBus#publish' do
            expect(request.size).to eq(2)
            expect(request.first).to eq('diego.staging.start')
            expect(request.last).to match_json(protocol.stage_app_message(app, staging_config))
          end
        end

        describe '#stage_app_message' do
          before do
            staging_override = {
              minimum_staging_memory_mb: 128,
              minimum_staging_disk_mb: 128,
              minimum_staging_file_descriptor_limit: 128,
              timeout_in_seconds: 90,
              auth: { user: 'user', password: 'password' },
            }
            TestConfig.override(staging: staging_override)
          end

          let(:message) { protocol.stage_app_message(app, staging_config) }
          let(:app) { AppFactory.make(staging_task_id: 'fake-staging-task-id') }
          let(:buildpack_generator) { BuildpackEntryGenerator.new(blobstore_url_generator) }

          it 'contains the correct payload for staging a Docker app' do
            expect(message).to eq({
              'app_id' => app.guid,
              'task_id' => 'fake-staging-task-id',
              'memory_mb' => app.memory,
              'disk_mb' => app.disk_quota,
              'file_descriptors' => app.file_descriptors,
              'environment' => Environment.new(app).as_json,
              'stack' => app.stack.name,
              'build_artifacts_cache_download_uri' => 'http://buildpack-artifacts-cache.com',
              'build_artifacts_cache_upload_uri' => 'http://buildpack-artifacts-cache.up.com',
              'app_bits_download_uri' => 'http://app-package.com',
              'buildpacks' => buildpack_generator.buildpack_entries(app),
              'droplet_upload_uri' => 'http://droplet-upload-uri',
              'egress_rules' => ['staging_egress_rule'],
              'timeout' => 90,
            })
          end

          context 'when the app memory is less than the minimum staging memory' do
            let(:app) { AppFactory.make(memory: 127) }

            subject(:message) do
              protocol.stage_app_message(app, staging_config)
            end

            it 'uses the minimum staging memory' do
              expect(message['memory_mb']).to eq(staging_config[:minimum_staging_memory_mb])
            end
          end

          context 'when the app disk is less than the minimum staging disk' do
            let(:app) { AppFactory.make(disk_quota: 127) }

            subject(:message) do
              protocol.stage_app_message(app, staging_config)
            end

            it 'includes the fields needed to stage a Docker app' do
              expect(message['disk_mb']).to eq(staging_config[:minimum_staging_disk_mb])
            end
          end

          context 'when the app fd limit is less than the minimum staging fd limit' do
            let(:app) { AppFactory.make(file_descriptors: 127) }

            subject(:message) do
              protocol.stage_app_message(app, staging_config)
            end

            it 'includes the fields needed to stage a Docker app' do
              expect(message['file_descriptors']).to eq(staging_config[:minimum_staging_file_descriptor_limit])
            end
          end
        end

        describe '#desire_app_request' do
          let(:request) { protocol.desire_app_request(app, default_health_check_timeout) }

          it 'returns arguments intended for CfMessageBus::MessageBus#publish' do
            expect(request.size).to eq(2)
            expect(request.first).to eq('diego.desire.app')
            expect(request.last).to match_json(protocol.desire_app_message(app, default_health_check_timeout))
          end
        end

        describe '#desire_app_message' do
          let(:app) do
            instance_double(App,
              execution_metadata: 'staging-metadata',
              desired_instances: 111,
              disk_quota: 222,
              file_descriptors: 333,
              guid: 'fake-guid',
              command: 'the-custom-command',
              health_check_type: 'some-health-check',
              health_check_timeout: 444,
              memory: 555,
              stack: instance_double(Stack, name: 'fake-stack'),
              version: 'version-guid',
              updated_at: Time.at(12345.6789),
              uris: ['fake-uris'],
            )
          end

          let(:message) { protocol.desire_app_message(app, default_health_check_timeout) }

          before do
            environment = instance_double(Environment, as_json: [{ 'name' => 'fake', 'value' => 'environment' }])
            allow(Environment).to receive(:new).with(app).and_return(environment)
          end

          it 'is a messsage with the information nsync needs to desire the app' do
            expect(message).to eq({
              'disk_mb' => 222,
              'droplet_uri' => 'fake-droplet_uri',
              'environment' => [{ 'name' => 'fake', 'value' => 'environment' }],
              'file_descriptors' => 333,
              'health_check_type' => 'some-health-check',
              'health_check_timeout_in_seconds' => 444,
              'log_guid' => 'fake-guid',
              'memory_mb' => 555,
              'num_instances' => 111,
              'process_guid' => 'fake-guid-version-guid',
              'stack' => 'fake-stack',
              'start_command' => 'the-custom-command',
              'execution_metadata' => 'staging-metadata',
              'routes' => ['fake-uris'],
              'egress_rules' => ['running_egress_rule'],
              'etag' => '12345.6789'
            })
          end

          context 'when the app health check timeout is not set' do
            before do
              TestConfig.override(default_health_check_timeout: default_health_check_timeout)
            end

            let(:app) { AppFactory.make(health_check_timeout: nil) }

            it 'uses the default app health check from the config' do
              expect(message['health_check_timeout_in_seconds']).to eq(default_health_check_timeout)
            end
          end
        end

        describe '#stop_staging_app_request' do
          let(:task_id) { 'staging_task_id' }
          let(:request) { protocol.stop_staging_app_request(app, task_id) }

          it 'returns an array of arguments including the subject and message' do
            expect(request.size).to eq(2)
            expect(request[0]).to eq('diego.staging.stop')
            expect(request[1]).to match_json(protocol.stop_staging_message(app, task_id))
          end
        end

        describe '#stop_staging_message' do
          let(:task_id) { 'staging_task_id' }
          let(:message) { protocol.stop_staging_message(app, task_id) }

          it 'is a nats message with the appropriate staging subject and payload' do
            expect(message).to eq(
              'app_id' => app.guid,
              'task_id' => task_id,
            )
          end
        end

        describe '#stop_index_request' do
          before { allow(common_protocol).to receive(:stop_index_request) }

          it 'delegates to the common protocol' do
            protocol.stop_index_request(app, 33)

            expect(common_protocol).to have_received(:stop_index_request).with(app, 33)
          end
        end
      end
    end
  end
end
