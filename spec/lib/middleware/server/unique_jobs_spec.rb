require 'spec_helper'
require 'sidekiq/cli'

module SidekiqUniqueJobs
  module Middleware
    module Server
      describe UniqueJobs do
        describe '#unlock_order_configured?' do
          context "when class isn't a Sidekiq::Worker" do
            it 'returns false' do
              expect(subject.unlock_order_configured?(Class))
                .to eq(false)
            end
          end

          context 'when get_sidekiq_options[:unique_unlock_order] is nil' do
            it 'returns false' do
              expect(subject.unlock_order_configured?(MyWorker))
                .to eq(false)
            end
          end

          it 'returns true when unique_unlock_order has been set' do
            test_worker_class = UniqueWorker.dup
            test_worker_class.sidekiq_options unique_unlock_order: :before_yield

            expect(subject.unlock_order_configured?(test_worker_class))
              .to eq(true)
          end
        end

        describe '#decide_unlock_order' do
          context 'when worker has specified unique_unlock_order' do
            it 'changes unlock_order to the configured value' do
              test_worker_class = UniqueWorker.dup
              test_worker_class.sidekiq_options unique_unlock_order: :before_yield

              expect do
                subject.decide_unlock_order(test_worker_class)
              end.to change { subject.unlock_order }.to :before_yield
            end
          end

          context "when worker hasn't specified unique_unlock_order" do
            it 'falls back to configured default_unlock_order' do
              SidekiqUniqueJobs.config.default_unlock_order = :before_yield

              expect do
                subject.decide_unlock_order(UniqueWorker)
              end.to change { subject.unlock_order }.to :before_yield
            end
          end
        end

        describe '#before_yield?' do
          it 'returns unlock_order == :before_yield' do
            allow(subject).to receive(:unlock_order).and_return(:after_yield)
            expect(subject.before_yield?).to eq(false)

            allow(subject).to receive(:unlock_order).and_return(:before_yield)
            expect(subject.before_yield?).to eq(true)
          end
        end

        describe '#after_yield?' do
          it 'returns unlock_order == :before_yield' do
            allow(subject).to receive(:unlock_order).and_return(:before_yield)
            expect(subject.after_yield?).to eq(false)

            allow(subject).to receive(:unlock_order).and_return(:after_yield)
            expect(subject.after_yield?).to eq(true)
          end
        end

        describe '#default_unlock_order' do
          it 'returns the default value from config' do
            SidekiqUniqueJobs.config.default_unlock_order = :before_yield
            expect(subject.default_unlock_order).to eq(:before_yield)

            SidekiqUniqueJobs.config.default_unlock_order = :after_yield
            expect(subject.default_unlock_order).to eq(:after_yield)
          end
        end

        describe '#call' do
          let(:uj) { SidekiqUniqueJobs::Middleware::Server::UniqueJobs.new }
          context 'unlock' do
            let(:items) { [AfterYieldWorker.new, { 'class' => 'testClass' }, 'test'] }

            it 'should unlock after yield when call succeeds' do
              expect(uj).to receive(:unlock)

              uj.call(*items) { true }
            end

            it 'should not unlock after yield when call errors' do
              expect(uj).to_not receive(:unlock)

              expect { uj.call(*items) { fail } }.to raise_error(RuntimeError)
            end
          end

          context "after unlock" do
            let(:items) { [AfterUnlockWorker.new, { 'class' => 'testClass' }, 'test'] }
            it 'should call the after_unlock hook if defined' do
              expect(uj).to receive(:unlock)
              expect_any_instance_of(AfterUnlockWorker).to receive(:after_unlock)

              uj.call(*items) { true }
            end
          end

          context "lock key" do
            it "should use unique_hash if supplied" do
              expect(uj).to receive(:unlock).with("supplied_hash")

              uj.call(UniqueWorker.new, { "class" => "testClass", "unique_hash" => "supplied_hash"}, "test") { true }
            end

            it "should compute the unique_hash if not supplied" do
              expect(uj).to receive(:unlock).with("sidekiq_unique:a401acaf0bfe131f5fc51439c09b9dd5")

              uj.call(UniqueWorker.new, { "class" => "testClass" }, "test") { true }
            end
          end

        end
      end
    end
  end
end
