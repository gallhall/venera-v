/**
 * Demo video source for venera-v.
 *
 * It plays public test streams and needs no account, so it can be used to
 * try the video source protocol. See video_source.md.
 *
 * A real source would fetch lists and play urls with `Network`; this one
 * keeps everything in a static catalog.
 */

const DEMO_COVER_BBB =
    "https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Big_buck_bunny_poster_big.jpg/330px-Big_buck_bunny_poster_big.jpg"
const DEMO_COVER_SINTEL =
    "https://upload.wikimedia.org/wikipedia/commons/thumb/8/8f/Sintel_poster.jpg/330px-Sintel_poster.jpg"

/**
 * Test clips in several qualities. `q` is the height.
 * @returns {VideoPlaySource[]}
 */
function demoClip(name, file) {
    return [720, 360].map((q) => new VideoPlaySource({
        name: `${q}P`,
        url: `https://test-videos.co.uk/vids/${name}/mp4/h264/${q}/${file}_${q}_10s_1MB.mp4`,
        type: "mp4",
    }))
}

const DEMO_VIDEOS = {
    bbb: {
        title: "Big Buck Bunny",
        cover: DEMO_COVER_BBB,
        description: "Multiple episodes: a full HLS stream and a short MP4 clip with an external subtitle.",
        tags: {"Format": ["HLS", "MP4"], "Feature": ["Episodes", "Subtitle"]},
        episodes: {
            full: "Full movie (HLS)",
            clip: "10s clip (MP4)",
        },
    },
    sintel: {
        title: "Sintel (clip)",
        cover: DEMO_COVER_SINTEL,
        description: "A video without episodes, in two qualities.",
        tags: {"Format": ["MP4"], "Feature": ["Qualities"]},
        episodes: null,
    },
    jellyfish: {
        title: "Jellyfish",
        cover: DEMO_COVER_BBB,
        description: "Request headers and an external audio track.",
        tags: {"Format": ["MP4"], "Feature": ["Headers", "External audio"]},
        episodes: null,
    },
    bipbop: {
        title: "Apple Bipbop",
        cover: DEMO_COVER_SINTEL,
        description: "HLS with multiple audio tracks and built-in subtitles.",
        tags: {"Format": ["HLS"], "Feature": ["Audio tracks", "Subtitle"]},
        episodes: null,
    },
    dash: {
        title: "Big Buck Bunny (DASH)",
        cover: DEMO_COVER_BBB,
        description: "MPEG-DASH stream.",
        tags: {"Format": ["DASH"]},
        episodes: null,
    },
    lines: {
        title: "Grouped episodes",
        cover: DEMO_COVER_SINTEL,
        description: "Episodes grouped by line, like sites that offer several mirrors.",
        tags: {"Feature": ["Grouped episodes"]},
        episodes: {
            "Line A": {"a1": "Episode 1", "a2": "Episode 2"},
            "Line B": {"b1": "Episode 1", "b2": "Episode 2"},
        },
    },
}

class DemoVideoSource extends ComicSource {
    name = "Demo Video"

    key = "demo_video"

    version = "1.0.0"

    // video sources need venera-v
    minAppVersion = "2.0.0"

    url = "https://cdn.jsdelivr.net/gh/gallhall/venera-v@master/doc/demo_video.js"

    mediaType = "video"

    toComic(id) {
        let v = DEMO_VIDEOS[id]
        return new Comic({
            id: id,
            title: v.title,
            subtitle: (v.tags["Format"] ?? []).join(" / "),
            cover: v.cover,
            tags: Object.values(v.tags).flat(),
            description: v.description,
        })
    }

    explore = [
        {
            title: "Demo Video",
            type: "multiPageComicList",
            load: async (page) => {
                return {
                    comics: Object.keys(DEMO_VIDEOS).map((id) => this.toComic(id)),
                    maxPage: 1,
                }
            },
        },
    ]

    search = {
        load: async (keyword, options, page) => {
            let k = keyword.toLowerCase()
            let ids = Object.keys(DEMO_VIDEOS).filter((id) => {
                let v = DEMO_VIDEOS[id]
                return v.title.toLowerCase().includes(k)
                    || Object.values(v.tags).flat().some((t) => t.toLowerCase().includes(k))
            })
            return {
                comics: ids.map((id) => this.toComic(id)),
                maxPage: 1,
            }
        },
        optionList: [],
    }

    // Details reuse `comic.loadInfo`; `chapters` are the episodes.
    comic = {
        loadInfo: async (id) => {
            let v = DEMO_VIDEOS[id]
            if (!v) {
                throw `Unknown video: ${id}`
            }
            return new ComicDetails({
                title: v.title,
                cover: v.cover,
                description: v.description,
                tags: v.tags,
                chapters: v.episodes,
            })
        },
    }

    video = {
        /**
         * Load the streams of an episode.
         * @param id {string}
         * @param epId {string?} - null if the video has no episodes
         * @returns {Promise<VideoPlayInfo>}
         */
        loadPlayInfo: async (id, epId) => {
            switch (id) {
                case "bbb":
                    if (epId === "full") {
                        return new VideoPlayInfo({
                            sources: [new VideoPlaySource({
                                name: "Auto",
                                url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8",
                                type: "hls",
                            })],
                        })
                    }
                    return new VideoPlayInfo({
                        sources: this.orderByQuality(demoClip("bigbuckbunny", "Big_Buck_Bunny")),
                        subtitles: [new VideoSubtitle({
                            name: "English",
                            language: "en",
                            url: "https://cdn.jsdelivr.net/gh/gallhall/venera-v@master/doc/demo_video.vtt",
                        })],
                    })
                case "sintel":
                    return new VideoPlayInfo({
                        sources: this.orderByQuality(demoClip("sintel", "Sintel")),
                    })
                case "jellyfish":
                    return new VideoPlayInfo({
                        sources: this.orderByQuality(demoClip("jellyfish", "Jellyfish")).map((s) => {
                            s.audioUrl = "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3"
                            return s
                        }),
                        // sent with every stream and subtitle request
                        headers: {
                            "Referer": "https://example.com/",
                        },
                    })
                case "bipbop":
                    // the shortest form: just a url
                    return "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"
                case "dash":
                    return {
                        url: "https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd",
                        type: "dash",
                    }
                case "lines":
                    // a real source would request the episode page here, e.g.
                    // let res = await Network.get(`https://example.com/play/${epId}`)
                    let clip = epId.endsWith("1") ? ["sintel", "Sintel"] : ["jellyfish", "Jellyfish"]
                    return new VideoPlayInfo({
                        sources: this.orderByQuality(demoClip(...clip)),
                    })
            }
            throw `Unknown video: ${id}`
        },
    }

    /**
     * Put the preferred quality first: the player starts with the first source.
     * @param sources {VideoPlaySource[]}
     */
    orderByQuality(sources) {
        let preferred = `${this.loadSetting("quality")}P`
        return [
            ...sources.filter((s) => s.name === preferred),
            ...sources.filter((s) => s.name !== preferred),
        ]
    }

    settings = {
        quality: {
            title: "Preferred quality",
            type: "select",
            options: [
                {value: "720", text: "720P"},
                {value: "360", text: "360P"},
            ],
            default: "720",
        },
    }

    translation = {
        "zh_CN": {
            "Demo Video": "示例视频",
            "Preferred quality": "首选画质",
        },
        "zh_TW": {
            "Demo Video": "示例影片",
            "Preferred quality": "首選畫質",
        },
    }
}
