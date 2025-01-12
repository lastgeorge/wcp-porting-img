// some functions to help build pipelines for imaging.  These are
// mostly per-apa but tiling portions are per-face.

local g = import 'pgraph.jsonnet';
local f = import 'pgrapher/common/funcs.jsonnet';
local wc = import 'wirecell.jsonnet';

{
    // A functio that sets up slicing for an APA.
    slicing :: function(anode, aname, tag="", span=4, active_planes=[1,2,4], masked_plane_charge=[]) {
        ret: g.pnode({
            type: "MaskSlices",
            name: "slicing-"+aname,
            data: {
                tag: tag,
                tick_span: span,
                anode: wc.tn(anode),
                tmax: -1,
                // active_planes: [1, 2],
                // masked_plane_charge: [[4, 1]],
                // active_planes: [1],
                // masked_plane_charge: [[2,1],[4, 1]],
                // active_planes: [],
                // masked_plane_charge: [[1,1],[2,1],[4, 1]],
            },
        }, nin=1, nout=1, uses=[anode]),
    }.ret,

    // A function sets up tiling for an APA incuding a per-face split.
    tiling :: function(anode, aname) {

        local slice_fanout = g.pnode({
            type: "SliceFanout",
            name: "slicefanout-" + aname,
            data: { multiplicity: 2 },
        }, nin=1, nout=2),

        local tilings = [g.pnode({
            type: "GridTiling",
            name: "tiling-%s-face%d"%[aname, face],
            data: {
                anode: wc.tn(anode),
                face: face,
            }
        }, nin=1, nout=1, uses=[anode]) for face in [0,1]],

        local blobsync = g.pnode({
            type: "BlobSetSync",
            name: "blobsetsync-" + aname,
            data: { multiplicity: 2 }
        }, nin=2, nout=1),

        // ret: g.intern(
        //     innodes=[slice_fanout],
        //     outnodes=[blobsync],
        //     centernodes=tilings,
        //     edges=
        //         [g.edge(slice_fanout, tilings[n], n, 0) for n in [0,1]] +
        //         [g.edge(tilings[n], blobsync, 0, n) for n in [0,1]],
        //     name='tiling-' + aname),
        ret : tilings[0],
    }.ret,

    //
    multi_active_slicing_tiling :: function(anode, name, tag="gauss", span=4) {
        local active_planes = [[1,2,4],[1,2],[2,4],[1,4],],
        local masked_plane_charge = [[],[[4,1]],[[1,1]],[[2,1]]],
        local iota = std.range(0,std.length(active_planes)-1),
        local slicings = [$.slicing(anode, name+"_%d"%n, tag, span, active_planes[n], masked_plane_charge[n]) 
            for n in iota],
        local tilings = [$.tiling(anode, name+"_%d"%n)
            for n in iota],
        local multipass = [g.pipeline([slicings[n],tilings[n]]) for n in iota],
        ret: f.fanpipe("FrameFanout", multipass, "BlobSetSync", "multi_active_slicing_tiling"),
    }.ret,

    //
    multi_masked_slicing_tiling :: function(anode, name, tag="gauss", span=109) {
        local active_planes = [[1],[2],[4],[],],
        local masked_charge = 1,
        local masked_plane_charge = [
            [[2,masked_charge],[4,masked_charge]],
            [[1,masked_charge],[4,masked_charge]],
            [[1,masked_charge],[2,masked_charge]],
            [[1,masked_charge],[2,masked_charge],[4,masked_charge]]
            ],
        local iota = std.range(0,std.length(active_planes)-1),
        local slicings = [$.slicing(anode, name+"_%d"%n, tag, span, active_planes[n], masked_plane_charge[n]) 
            for n in iota],
        local tilings = [$.tiling(anode, name+"_%d"%n)
            for n in iota],
        local multipass = [g.pipeline([slicings[n],tilings[n]]) for n in iota],
        ret: f.fanpipe("FrameFanout", multipass, "BlobSetSync", "multi_masked_slicing_tiling"),
    }.ret,

    // Just clustering
    clustering :: function(anode, aname, spans=1.0) {
        ret : g.pnode({
            type: "BlobClustering",
            name: "blobclustering-" + aname,
            data:  { spans : spans }
        }, nin=1, nout=1),
    }.ret, 

    // this bundles clustering, grouping and solving.  Other patterns
    // should be explored.  Note, anode isn't really needed, we just
    // use it for its ident and to keep similar calling pattern to
    // above..
    solving :: function(anode, aname, spans=1.0, threshold=0.0) {
        local bc = g.pnode({
            type: "BlobClustering",
            name: "blobclustering-" + aname,
            data:  { spans : spans }
        }, nin=1, nout=1),
        local bg = g.pnode({
            type: "BlobGrouping",
            name: "blobgrouping-" + aname,
            data:  {
            }
        }, nin=1, nout=1),
        local bs = g.pnode({
            type: "BlobSolving",
            name: "blobsolving-" + aname,
            data:  { threshold: threshold }
        }, nin=1, nout=1),
        ret: g.intern(
            innodes=[bc], outnodes=[bs], centernodes=[bg],
            edges=[g.edge(bc,bg), g.edge(bg,bs)],
            name="solving-" + aname),
        // ret: bc,
    }.ret,

    dump :: function(anode, aname, drift_speed) {
        local js = g.pnode({
            type: "JsonClusterTap",
            name: "clustertap-" + aname,
            data: {
                filename: "clusters-"+aname+"-%04d.json",
                drift_speed: drift_speed
            },
        }, nin=1, nout=1),

        local cs = g.pnode({
            type: "ClusterSink",
            name: "clustersink-"+aname,
            data: {
                filename: "clusters-apa-"+aname+"-%d.dot",
            }
        }, nin=1, nout=0),
        ret: g.intern(innodes=[js], outnodes=[cs], edges=[g.edge(js,cs)],
                      name="clusterdump-"+aname)
    }.ret,

    // A function that reverts blobs to frames
    reframing :: function(anode, aname) {
        ret : g.pnode({
            type: "BlobReframer",
            name: "blobreframing-" + aname,
            data: {
                frame_tag: "reframe%d" %anode.data.ident,
            }
        }, nin=1, nout=1),
    }.ret,

    // fill ROOT histograms with frames
    magnify :: function(anode, aname, frame_tag="orig") {
        ret: g.pnode({
          type: 'MagnifySink',
          name: 'magnify-'+aname,
          data: {
            output_filename: "magnify-img.root",
            root_file_mode: 'UPDATE',
            frames: [frame_tag + anode.data.ident],
            trace_has_tag: true,
            anode: wc.tn(anode),
          },
        }, nin=1, nout=1),
    }.ret,

    // the end
    dumpframes :: function(anode, aname) {
        ret: g.pnode({
            type: "DumpFrames",
            name: "dumpframes-"+aname,
        }, nin=1, nout=0),
    }.ret,

}
