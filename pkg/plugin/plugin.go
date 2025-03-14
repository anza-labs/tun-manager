// Copyright 2025 anza-labs contributors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package plugin

import (
	"context"
	"fmt"
	"log/slog"
	"path/filepath"
	"time"

	"github.com/grpc-ecosystem/go-grpc-middleware/v2/interceptors/logging"
	"github.com/grpc-ecosystem/go-grpc-middleware/v2/interceptors/recovery"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health/grpc_health_v1"

	"github.com/anza-labs/tun-manager/pkg/metrics"

	"k8s.io/kubelet/pkg/apis/deviceplugin/v1beta1"
)

type Plugin struct {
	log *slog.Logger
}

func New(log *slog.Logger) *Plugin {
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}

	return &Plugin{
		log: log,
	}
}

func (p *Plugin) DevicePluginServer(plugin v1beta1.DevicePluginServer) *grpc.Server {
	srv := grpc.NewServer(
		grpc.ChainUnaryInterceptor(
			metrics.GRPCServerMetrics.UnaryServerInterceptor(),
			logging.UnaryServerInterceptor(&grpcLogger{log: p.log}),
			recovery.UnaryServerInterceptor(recovery.WithRecoveryHandler(grpcRecovery(p.log))),
		),
		grpc.ChainStreamInterceptor(
			metrics.GRPCServerMetrics.StreamServerInterceptor(),
			logging.StreamServerInterceptor(&grpcLogger{log: p.log}),
			recovery.StreamServerInterceptor(recovery.WithRecoveryHandler(grpcRecovery(p.log))),
		),
	)

	metrics.GRPCServerMetrics.InitializeMetrics(srv)
	v1beta1.RegisterDevicePluginServer(srv, plugin)

	return srv
}

func (p *Plugin) RegisterDevicePlugin(ctx context.Context, name, socket string) error {
	if err := p.waitForPluginReady(ctx, name, socket); err != nil {
		return fmt.Errorf("plugin not ready: %w", err)
	}

	if err := p.registerWithKubelet(ctx, name, socket); err != nil {
		return fmt.Errorf("registration failed: %w", err)
	}

	return nil
}

func (p *Plugin) connectGRPCWithRetry(socket string) (*grpc.ClientConn, error) {
	var conn *grpc.ClientConn

	err := p.retry(func() error {
		var err error
		conn, err = grpc.NewClient(
			socket,
			grpc.WithTransportCredentials(insecure.NewCredentials()),
		)
		return err
	})

	return conn, err
}

func (p *Plugin) retry(op func() error) error {
	baseDelay := 100 * time.Millisecond // Initial backoff delay
	maxDelay := 5 * time.Second         // Maximum backoff delay
	maxRetries := 5                     // Maximum retry attempts

	var err error
	for attempt := 0; attempt < maxRetries; attempt++ {
		err = op()
		if err == nil {
			return nil
		}

		backoffDelay := baseDelay * (1 << attempt)
		if backoffDelay > maxDelay {
			backoffDelay = maxDelay
		}

		p.log.Debug("Failure, retrying", "backoff", backoffDelay)
		time.Sleep(backoffDelay)
	}

	return fmt.Errorf(
		"failed to create connection to local gRPC server after %d attempts: %w",
		maxRetries, err,
	)
}

func (p *Plugin) waitForPluginReady(ctx context.Context, name, socket string) error {
	p.log.Info("Waiting for socket ready", "name", name, "socket", socket)

	conn, err := p.connectGRPCWithRetry(socket)
	if err != nil {
		return fmt.Errorf("failed to create connection to local gRPC server: %w", err)
	}
	defer conn.Close() //nolint:errcheck // best effort call

	health := grpc_health_v1.NewHealthClient(conn)
	err = p.retry(func() error {
		res, err := health.Check(ctx, &grpc_health_v1.HealthCheckRequest{Service: name})
		if err != nil {
			return err
		}
		if res.Status != grpc_health_v1.HealthCheckResponse_SERVING {
			return fmt.Errorf("invalid status: %v", res.Status)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("failed to check health of the service: %w", err)
	}

	return nil
}

func (p *Plugin) registerWithKubelet(ctx context.Context, name, socket string) error {
	p.log.Info("Registering device plugin",
		"name", name,
		"socket", socket,
		"kubelet", v1beta1.KubeletSocket,
	)

	conn, err := p.connectGRPCWithRetry(fmt.Sprintf("unix://%s", v1beta1.KubeletSocket))
	if err != nil {
		return fmt.Errorf("failed to connect to kubelet: %v", err)
	}
	defer conn.Close() //nolint:errcheck // best effort call

	_, err = v1beta1.NewRegistrationClient(conn).Register(ctx, &v1beta1.RegisterRequest{
		Version:      v1beta1.Version,
		ResourceName: name,
		Endpoint:     filepath.Base(socket),
	})
	if err != nil {
		return fmt.Errorf("failed to register plugin with kubelet service: %v", err)
	}

	return nil
}

type grpcLogger struct {
	log *slog.Logger
}

func (g *grpcLogger) Log(ctx context.Context, _ logging.Level, msg string, kv ...any) {
	g.log.Debug(msg, kv...)
}

func grpcRecovery(log *slog.Logger) func(p any) (err error) {
	return func(p any) (err error) {
		log.Error("Panic recovery", "panic", p)
		metrics.PanicCounter.Inc()
		return nil
	}
}
