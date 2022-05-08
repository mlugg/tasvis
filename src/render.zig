const std = @import("std");
const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libswscale/swscale.h");
});

pub fn render(filename: [*:0]const u8, frame_producer: anytype) !void {
    // create a format context to write the mp4 container
    var fmt_ctx = try AvFormatContext.openOutput(filename);
    defer fmt_ctx.closeOutput();

    // create a h.264 encoder
    var enc_ctx = try AvCodecContext.open(
        fmt_ctx,
        c.AV_CODEC_ID_H264,
        frame_producer.getRate(),
        .{
            .width = frame_producer.getWidth(),
            .height = frame_producer.getHeight(),
            .pix_fmt = c.AV_PIX_FMT_YUV420P,
        },
    );
    defer enc_ctx.close();

    // create a stream in the output file based on this codec
    const stream = try fmt_ctx.createCodecStream(enc_ctx);

    // now we've added all our streams, write the file header
    try fmt_ctx.writeHeader();

    // frame in source format
    var tmp_frame = try AvFrame.initVideo(.{
        .width = frame_producer.getWidth(),
        .height = frame_producer.getHeight(),
        .pix_fmt = c.AV_PIX_FMT_RGB24,
    });
    defer tmp_frame.deinit();

    // frame in output format
    var frame = try AvFrame.initVideo(enc_ctx.frameInfo());
    defer frame.deinit();

    // sws context to convert between the frame formats
    var sws_ctx = try SwScaleContext.init(tmp_frame.getInfo(), frame.getInfo());
    defer sws_ctx.deinit();

    var pts: u32 = 0;
    while (frame_producer.hasFrame()) {
        // init rgb data
        frame_producer.generate(try tmp_frame.rgbData());

        // convert to destination format
        try sws_ctx.scale(tmp_frame, frame);

        // set timestamp (frame number)
        frame.setPts(pts);
        pts += 1;

        // send the frame to the encoder and flush any pending data to the output video
        try enc_ctx.sendFrame(frame);
        try stream.flushPackets();
    }

    // signal end of stream to the encoder and flush pending stream data
    try enc_ctx.sendFrame(null);
    try stream.flushPackets();

    // write the file trailer
    try fmt_ctx.writeTrailer();
}

const AvFormatContext = struct {
    _ptr: *c.AVFormatContext,

    pub fn openOutput(filename: [*:0]const u8) !AvFormatContext {
        var ctx: ?*c.AVFormatContext = undefined;
        if (c.avformat_alloc_output_context2(&ctx, null, null, filename) < 0) {
            return error.FormatContextCreationError;
        }
        errdefer c.avformat_free_context(ctx);

        if (c.avio_open(&ctx.?.pb, filename, c.AVIO_FLAG_WRITE) < 0) {
            return error.FileOpenError;
        }
        errdefer c.avio_closep(&ctx.?.pb);

        return AvFormatContext{
            ._ptr = ctx.?,
        };
    }

    pub fn closeOutput(self: AvFormatContext) void {
        _ = c.avio_closep(&self._ptr.pb);
        _ = c.avformat_free_context(self._ptr);
    }

    pub fn createCodecStream(self: AvFormatContext, codec: AvCodecContext) !AvStream {
        const stream = c.avformat_new_stream(self._ptr, null) orelse
            return error.StreamCreationError;

        if (c.avcodec_parameters_from_context(stream.*.codecpar, codec._ptr) < 0) {
            return error.StreamParameterInitError;
        }

        return AvStream{
            ._format = self,
            ._codec = codec,
            ._ptr = stream,
        };
    }

    pub fn writeHeader(self: AvFormatContext) !void {
        if (c.avformat_write_header(self._ptr, null) < 0) {
            return error.HeaderWriteError;
        }
    }

    pub fn writeTrailer(self: AvFormatContext) !void {
        if (c.av_write_trailer(self._ptr) < 0) {
            return error.HeaderWriteError;
        }
    }
};

const AvStream = struct {
    _format: AvFormatContext,
    _codec: AvCodecContext,
    _ptr: *c.AVStream,

    pub fn flushPackets(self: AvStream) !void {
        while (self._codec.receivePacket()) |pkt| {
            var p1 = pkt;
            c.av_packet_rescale_ts(&p1, self._codec._ptr.time_base, self._ptr.time_base);
            p1.stream_index = self._ptr.index;
            if (c.av_interleaved_write_frame(self._format._ptr, &p1) < 0) {
                return error.WritePacketError;
            }
            c.av_packet_unref(&p1);
        }
    }
};

const AvCodecContext = struct {
    _ptr: *c.AVCodecContext,

    pub fn open(fmt_ctx: AvFormatContext, id: c.AVCodecID, fps: u16, frame_info: AvFrame.Info) !AvCodecContext {
        var codec = c.avcodec_find_encoder(id) orelse
            return error.CodecFindError;

        var ctx = c.avcodec_alloc_context3(codec) orelse
            return error.CodecContextCreationError;
        errdefer c.avcodec_free_context(&ctx);

        ctx.*.width = frame_info.width;
        ctx.*.height = frame_info.height;
        ctx.*.pix_fmt = frame_info.pix_fmt;
        ctx.*.time_base = c.AVRational{ .num = 1, .den = fps };
        ctx.*.framerate = c.AVRational{ .num = fps, .den = 1 };
        ctx.*.codec_id = id;

        if ((fmt_ctx._ptr.oformat.*.flags & c.AVFMT_GLOBALHEADER) != 0) {
            ctx.*.flags |= c.AV_CODEC_FLAG_GLOBAL_HEADER;
        }

        if (c.avcodec_open2(ctx, codec, null) < 0) {
            return error.CodecOpenError;
        }

        return AvCodecContext{
            ._ptr = ctx,
        };
    }

    pub fn close(self: AvCodecContext) void {
        var p: ?*c.AVCodecContext = self._ptr;
        _ = c.avcodec_free_context(&p);
    }

    pub fn frameInfo(self: AvCodecContext) AvFrame.Info {
        return .{
            .width = @intCast(u16, self._ptr.width),
            .height = @intCast(u16, self._ptr.height),
            .pix_fmt = self._ptr.pix_fmt,
        };
    }

    fn receivePacket(self: AvCodecContext) ?c.AVPacket {
        var pkt = std.mem.zeroes(c.AVPacket);
        if (c.avcodec_receive_packet(self._ptr, &pkt) != 0) return null;
        return pkt;
    }

    pub fn sendFrame(self: AvCodecContext, frame: ?AvFrame) !void {
        var frame_ptr = if (frame) |f| f._ptr else null;

        if (c.avcodec_send_frame(self._ptr, frame_ptr) < 0) {
            return error.FrameSendError;
        }
    }
};

const AvFrame = struct {
    _ptr: *c.AVFrame,

    const Info = struct {
        width: u16,
        height: u16,
        pix_fmt: c.AVPixelFormat,
    };

    pub fn initVideo(info: Info) !AvFrame {
        var frame = c.av_frame_alloc() orelse
            return error.FrameCreationError;
        errdefer c.av_frame_free(&frame);

        frame.*.format = info.pix_fmt;
        frame.*.width = info.width;
        frame.*.height = info.height;

        if (info.pix_fmt == c.AV_PIX_FMT_RGB24) {
            // force linesize to remove padding
            frame.*.linesize[0] = @as(c_int, info.width) * 3;
        }

        if (c.av_frame_get_buffer(frame, 32) < 0) {
            return error.FrameBufferAllocationError;
        }

        return AvFrame{ ._ptr = frame };
    }

    pub fn deinit(self: AvFrame) void {
        var f: ?*c.AVFrame = self._ptr;
        c.av_frame_free(&f);
    }

    pub fn setPts(self: AvFrame, pts: u32) void {
        self._ptr.pts = pts;
    }

    pub fn getInfo(self: AvFrame) Info {
        return .{
            .width = @intCast(u16, self._ptr.width),
            .height = @intCast(u16, self._ptr.height),
            .pix_fmt = self._ptr.format,
        };
    }

    pub fn rgbData(self: AvFrame) ![][3]u8 {
        const info = self.getInfo();
        if (info.pix_fmt != c.AV_PIX_FMT_RGB24) {
            return error.BadPixelFormat;
        }
        const len = @as(usize, info.width) * @as(usize, info.height);
        return @ptrCast([*][3]u8, self._ptr.data[0])[0..len];
    }
};

const SwScaleContext = struct {
    _ptr: *c.SwsContext,

    pub fn init(src_info: AvFrame.Info, dst_info: AvFrame.Info) !SwScaleContext {
        const ctx = c.sws_getContext(
            src_info.width,
            src_info.height,
            src_info.pix_fmt,
            dst_info.width,
            dst_info.height,
            dst_info.pix_fmt,
            c.SWS_BICUBIC,
            null,
            null,
            null,
        ) orelse return error.ScaleContextCreationError;

        return SwScaleContext{ ._ptr = ctx };
    }

    pub fn deinit(self: SwScaleContext) void {
        c.sws_freeContext(self._ptr);
    }

    pub fn scale(self: SwScaleContext, src: AvFrame, dst: AvFrame) !void {
        if (c.sws_scale(
            self._ptr,
            &src._ptr.data,
            &src._ptr.linesize,
            0,
            src._ptr.height,
            &dst._ptr.data,
            &dst._ptr.linesize,
        ) < 0) {
            return error.ScaleError;
        }
    }
};
