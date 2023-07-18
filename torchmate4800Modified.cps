/**
  Copyright (C) 2012-2021 by Autodesk, Inc.
  All rights reserved.

  Torchmate Mill/Plasma post processor configuration.

  $Revision: 43531 953e9052f83a5e7ebe58d54b0f5357eca5369a48 $
  $Date: 2021-11-25 13:38:02 $

  FORKID {7B91741C-EF71-49D7-9E87-E53C2C071888}
*/

/* additional commands
M100 Wait for input line (normal state)
M101 Wait for input line (tripped state)
*/

description = "Torchmate 4400/4800 Plasma Cutter";
vendor = "Torchmate";
vendorUrl = "http://torchmate.com";
legal = "Copyright (C) 2012-2021 by Autodesk, Inc.";
certificationLevel = 2;
minimumRevision = 45702;

longDescription = "Customized file to output for Torchmate 4400/4800. Enable property 'useZ' to output Z moves. Turn off property 'useWorkOffsets' if G54, G55, ... work offsets are not used. Disable property 'useM30' to avoid M30 at end of program. Disable property 'useCoolant' to avoid coolant M-codes. Disable property 'useTool' if tool calls should not be output.";

extension = "gm";
setCodePage("ascii");

capabilities = CAPABILITY_MILLING | CAPABILITY_JET;
tolerance = spatial(0.002, MM);

minimumChordLength = spatial(0.25, MM);
minimumCircularRadius = spatial(0.01, MM);
maximumCircularRadius = spatial(1000, MM);
minimumCircularSweep = toRad(0.01);
maximumCircularSweep = toRad(180);
allowHelicalMoves = true; // for milling
allowedCircularPlanes = undefined; // allow any circular motion

// user-defined properties
properties = {
  writeMachine: {
    title      : "Write machine",
    description: "Output the machine settings in the header of the code.",
    group      : 0,
    type       : "boolean",
    value      : true,
    scope      : "post"
  },
  showSequenceNumbers: {
    title      : "Use sequence numbers",
    description: "Use sequence numbers for each block of outputted code.",
    group      : 1,
    type       : "boolean",
    value      : true,
    scope      : "post"
  },
  sequenceNumberStart: {
    title      : "Start sequence number",
    description: "The number at which to start the sequence numbers.",
    group      : 1,
    type       : "integer",
    value      : 10,
    scope      : "post"
  },
  sequenceNumberIncrement: {
    title      : "Sequence number increment",
    description: "The amount by which the sequence number is incremented by in each block.",
    group      : 1,
    type       : "integer",
    value      : 1,
    scope      : "post"
  },
  separateWordsWithSpace: {
    title      : "Separate words with space",
    description: "Adds spaces between words if 'yes' is selected.",
    type       : "boolean",
    value      : true,
    scope      : "post"
  },
  useRadius: {
    title      : "Radius arcs",
    description: "If yes is selected, arcs are outputted using radius values rather than IJK.",
    type       : "boolean",
    value      : false,
    scope      : "post"
  },
  dwellInSeconds: {
    title      : "Dwell in seconds",
    description: "Specifies the unit for dwelling, set to 'Yes' for seconds and 'No' for milliseconds.",
    type       : "boolean",
    value      : true,
    scope      : "post"
  },
  useZ: {
    title      : "Use Z Values",
    description: "If disabled, all Z values are ommited.",
    type       : "boolean",
    value      : false,
    scope      : "post"
  },
  useWorkOffsets: {
    title      : "Use work offsets",
    description: "Enable to allow the use of work offsets.",
    type       : "boolean",
    value      : true,
    scope      : "post"
  },
  useCoolant: {
    title      : "Use coolant",
    description: "Enable to ouput coolant commands.",
    type       : "boolean",
    value      : true,
    scope      : "post"
  },
  useTool: {
    title      : "Use tool",
    description: "Enable to ouptut tool calls. E.g. T1.",
    type       : "boolean",
    value      : true,
    scope      : "post"
  },
  useM30: {
    title      : "Use M30",
    description: "Enable to output M30 for program end.",
    type       : "boolean",
    value      : true,
    scope      : "post"
  }
};

// wcs definiton
wcsDefinitions = {
  useZeroOffset: false,
  wcs          : [
    {name:"Standard", format:"G", range:[54, 59]},
    {name:"Extended", format:"G54.1 P", range:[1, 99]}
  ]
};

var mapCoolantTable = new Table(
  [9, 8, 7],
  {initial:COOLANT_OFF, force:true},
  "Invalid coolant mode"
);

var gFormat = createFormat({prefix:"G", decimals:1});
var mFormat = createFormat({prefix:"M", decimals:0});
var hFormat = createFormat({prefix:"H", decimals:0});
var dFormat = createFormat({prefix:"D", decimals:0});

var xyzFormat = createFormat({decimals:(unit == MM ? 3 : 4), forceDecimal:true, force:false});
var rFormat = xyzFormat; // radius
var feedFormat = createFormat({decimals:(unit == MM ? 1 : 2), forceDecimal:true});
var toolFormat = createFormat({decimals:0});
var rpmFormat = createFormat({decimals:0});
var secFormat = createFormat({decimals:3, forceDecimal:true}); // seconds - range 0.001-99999.999
var milliFormat = createFormat({decimals:0}); // milliseconds // range 1-9999

var xOutput = createVariable({prefix:"X", force:false}, xyzFormat);
var yOutput = createVariable({prefix:"Y", force:false}, xyzFormat);
var zOutput = createVariable({prefix:"Z", force:false}, xyzFormat);

var feedOutput = createVariable({prefix:"F"}, feedFormat);
var sOutput = createVariable({prefix:"S", force:true}, rpmFormat);

// circular output
var iOutput = createReferenceVariable({prefix:"I", force:true}, xyzFormat);
var jOutput = createReferenceVariable({prefix:"J", force:true}, xyzFormat);
var kOutput = createReferenceVariable({prefix:"K", force:true}, xyzFormat);

var gMotionModal = createModal({force:false}, gFormat); // modal group 1 // G0-G3
var gPlaneModal = createModal({onchange:function () {gMotionModal.reset();}}, gFormat); // modal group 2 // G17-19
var gAbsIncModal = createModal({}, gFormat); // modal group 3 // G90-91
var gUnitModal = createModal({}, gFormat); // modal group 6 // G20-21 or G70-71
var gCycleModal = createModal({}, gFormat); // modal group 9 // G81, ...
var gRetractModal = createModal({}, gFormat); // modal group 10 // G98-99

var WARNING_WORK_OFFSET = 0;

// collected state
var sequenceNumber;
var currentWorkOffset;

/**
  Writes the specified block.
*/
function writeBlock() {
  if (getProperty("showSequenceNumbers")) {
    writeWords2("N" + (sequenceNumber % 100000), arguments);
    sequenceNumber += getProperty("sequenceNumberIncrement");
  } else {
    writeWords(arguments);
  }
}

/**
  Writes the specified optional block.
*/
function writeOptionalBlock() {
  if (getProperty("showSequenceNumbers")) {
    var words = formatWords(arguments);
    if (words) {
      writeWords("/", "N" + (sequenceNumber % 10000), words);
      sequenceNumber += getProperty("sequenceNumberIncrement");
      if (sequenceNumber >= 10000) {
        sequenceNumber = getProperty("sequenceNumberStart");
      }
    }
  } else {
    writeWords2("/", arguments);
  }
}

function formatComment(text) {
  return "(" + String(text).replace(/[()]/g, "") + ")";
}

/**
  Output a comment.
*/
function writeComment(text) {
  writeln(formatComment(text));
}

function onOpen() {
  if (getProperty("useRadius")) {
    maximumCircularSweep = toRad(90); // avoid potential center calculation errors for CNC
  }

  if (!getProperty("useZ")) {
    zOutput.disable();
  }

  if (!getProperty("separateWordsWithSpace")) {
    setWordSeparator("");
  }

  sequenceNumber = getProperty("sequenceNumberStart");

  if (programComment) {
    writeComment(programComment);
  }

  // dump machine configuration
  var vendor = machineConfiguration.getVendor();
  var model = machineConfiguration.getModel();
  var description = machineConfiguration.getDescription();

  if (getProperty("writeMachine") && (vendor || model || description)) {
    writeComment(localize("Machine"));
    if (vendor) {
      writeComment("  " + localize("vendor") + ": " + vendor);
    }
    if (model) {
      writeComment("  " + localize("model") + ": " + model);
    }
    if (description) {
      writeComment("  " + localize("description") + ": "  + description);
    }
  }

  switch (unit) {
  case IN:
    writeBlock(gUnitModal.format(70)); // or use M20
    break;
  case MM:
    writeBlock(gUnitModal.format(71)); // or use M21
    break;
  }

  if ((getNumberOfSections() > 0) && (getSection(0).workOffset == 0)) {
    for (var i = 0; i < getNumberOfSections(); ++i) {
      if (getSection(i).workOffset > 0) {
        error(localize("Using multiple work offsets is not possible if the initial work offset is 0."));
        return;
      }
    }
  }

  // absolute coordinates
  if (getProperty("useZ")) {
    writeBlock(gAbsIncModal.format(90), conditional(getProperty("useZ"), gPlaneModal.format(17)));
  } else {
    writeBlock(gAbsIncModal.format(90));
  }
}

function onComment(message) {
  writeComment(message);
}

/** Force output of X, Y, and Z. */
function forceXYZ() {
  xOutput.reset();
  yOutput.reset();
}

/** Force output of X, Y, Z, and F on next output. */
function forceAny() {
  forceXYZ();
  feedOutput.reset();
}

function onSection() {
  var insertToolCall = isFirstSection() ||
    currentSection.getForceToolChange && currentSection.getForceToolChange() ||
    (tool.number != getPreviousSection().getTool().number);

  var retracted = false; // specifies that the tool has been retracted to the safe plane
  var newWorkOffset = isFirstSection() ||
    (getPreviousSection().workOffset != currentSection.workOffset); // work offset changes
  var newWorkPlane = isFirstSection() ||
    !isSameDirection(getPreviousSection().getGlobalFinalToolAxis(), currentSection.getGlobalInitialToolAxis());
  if (insertToolCall || newWorkOffset || newWorkPlane) {

    // stop spindle before retract during tool change
    if (insertToolCall && !isFirstSection()) {
      onCommand(COMMAND_STOP_SPINDLE);
    }

    // retract to safe plane
    if (getProperty("useZ")) {
      retracted = true;
      writeBlock(gFormat.format(28), gAbsIncModal.format(91), "Z" + xyzFormat.format(0)); // retract
      writeBlock(gAbsIncModal.format(90));
      zOutput.reset();
    }
  }

  writeln("");

  if (hasParameter("operation-comment")) {
    var comment = getParameter("operation-comment");
    if (comment) {
      writeComment(comment);
    }
  }

  if (getProperty("useTool")) {
    if (currentSection.type == TYPE_JET) {
      switch (tool.type) {
      case TOOL_PLASMA_CUTTER:
        break;
      /*
      case TOOL_MARKER:
        break;
      */
      default:
        error(localize("The CNC does not support the required tool/process. Only plasma cutting is supported."));
        return;
      }

      switch (currentSection.jetMode) {
      case JET_MODE_THROUGH:
        break;
      case JET_MODE_ETCHING:
        break;
      case JET_MODE_VAPORIZE:
        error(localize("Vaporize cutting mode is not supported."));
        break;
      default:
        error(localize("Unsupported cutting mode."));
        return;
      }

      var toolNumber = 1; // plasma
      if (currentSection.jetMode == JET_MODE_ETCHING) {
        toolNumber = 2; // marker
      }
      writeBlock(mFormat.format(6), "T" + toolFormat.format(toolNumber));
    } else {
      writeBlock(mFormat.format(6), "T" + toolFormat.format(tool.number));
    }
  }
  if (tool.comment) {
    writeComment(tool.comment);
  }

  if ((currentSection.type == TYPE_MILLING) &&
      (insertToolCall ||
       isFirstSection() ||
       (rpmFormat.areDifferent(spindleSpeed, sOutput.getCurrent())) ||
       (tool.clockwise != getPreviousSection().getTool().clockwise))) {
    if (spindleSpeed < 1) {
      error(localize("Spindle speed out of range."));
    }
    if (spindleSpeed > 99999) {
      warning(localize("Spindle speed exceeds maximum value."));
    }
    writeBlock(
      sOutput.format(spindleSpeed), mFormat.format(tool.clockwise ? 3 : 4)
    );
  }

  // wcs
  if (getProperty("useWorkOffsets")) {
    if (insertToolCall) { // force work offset when changing tool
      currentWorkOffset = undefined;
    }

    if (currentSection.workOffset != currentWorkOffset) {
      writeBlock(currentSection.wcs);
      currentWorkOffset = currentSection.workOffset;
    }
  }

  { // pure 3D
    var remaining = currentSection.workPlane;
    if (!isSameDirection(remaining.forward, new Vector(0, 0, 1))) {
      error(localize("Tool orientation is not supported."));
      return;
    }
    setRotation(remaining);
  }

  // set coolant after we have positioned at Z
  if (getProperty("useCoolant")) {
    var c = mapCoolantTable.lookup(tool.coolant);
    if (c) {
      writeBlock(mFormat.format(c));
    } else {
      warning(localize("Coolant not supported."));
    }
  }

  forceAny();

  var initialPosition = getFramePosition(currentSection.getInitialPosition());
  if (!retracted && getProperty("useZ") && !insertToolCall) {
    if (getCurrentPosition().z < initialPosition.z) {
      writeBlock(gMotionModal.format(0), zOutput.format(initialPosition.z));
    }
  }

  gMotionModal.reset();

  if (true) {
    gMotionModal.reset();
    writeBlock(conditional(getProperty("useZ"), gPlaneModal.format(17)));

    if (getProperty("useZ")) {
      writeBlock(
        gAbsIncModal.format(90),
        gMotionModal.format(0), gFormat.format(43),
        xOutput.format(initialPosition.x), yOutput.format(initialPosition.y), zOutput.format(initialPosition.z),
        hFormat.format(tool.lengthOffset)
      );
    } else {
      writeBlock(
        gAbsIncModal.format(90),
        gMotionModal.format(0),
        xOutput.format(initialPosition.x), yOutput.format(initialPosition.y)
      );
    }
  } else {
    writeBlock(
      gAbsIncModal.format(90),
      gMotionModal.format(0),
      xOutput.format(initialPosition.x),
      yOutput.format(initialPosition.y),
      zOutput.format(initialPosition.z)
    );
  }

  writeBlock(
    gAbsIncModal.format(90),
    gMotionModal.format(0),
    xOutput.format(initialPosition.x), yOutput.format(initialPosition.y), zOutput.format(initialPosition.z)
  );

  // could use G31 Zz Ii Ss Cc Ff for seek sensing
}

function onDwell(seconds) {
  if (seconds > 99999.999) {
    warning(localize("Dwelling time is out of range."));
  }
  if (getProperty("dwellInSeconds")) {
    writeBlock(gFormat.format(4), "X" + secFormat.format(seconds));
  } else {
    // P unit is setting in control!
    var milliseconds = clamp(1, seconds * 1000, 99999999);
    writeBlock(gFormat.format(4), "P" + milliFormat.format(milliseconds));
  }
}

function onSpindleSpeed(spindleSpeed) {
  writeBlock(sOutput.format(spindleSpeed));
}

function onCycle() {
  writeBlock(conditional(getProperty("useZ"), gPlaneModal.format(17)));
}

function getCommonCycle(x, y, z, r) {
  forceXYZ();
  return [xOutput.format(x), yOutput.format(y),
    zOutput.format(z),
    "R" + xyzFormat.format(r)];
}

function onCyclePoint(x, y, z) {
  if (!getProperty("useZ")) {
    error(localize("Z must be enabled by setting the 'useZ' property to use drilling cycles."));
    return;
  }
  if (!isSameDirection(getRotation().forward, new Vector(0, 0, 1))) {
    expandCyclePoint(x, y, z);
    return;
  }

  if (isFirstCyclePoint()) {
    repositionToCycleClearance(cycle, x, y, z);

    // return to initial Z which is clearance plane and set absolute mode

    var F = cycle.feedrate;
    var P = !cycle.dwell ? 0 : clamp(1, cycle.dwell * 1000, 99999); // in milliseconds

    switch (cycleType) {
    case "drilling":
      writeBlock(
        gRetractModal.format(98), gAbsIncModal.format(90), gCycleModal.format(81),
        getCommonCycle(x, y, z, cycle.retract),
        feedOutput.format(F)
      );
      break;
    case "counter-boring":
      if (P > 0) {
        writeBlock(
          gRetractModal.format(98), gAbsIncModal.format(90), gCycleModal.format(82),
          getCommonCycle(x, y, z, cycle.retract),
          "P" + milliFormat.format(P),
          feedOutput.format(F)
        );
      } else {
        writeBlock(
          gRetractModal.format(98), gAbsIncModal.format(90), gCycleModal.format(81),
          getCommonCycle(x, y, z, cycle.retract),
          feedOutput.format(F)
        );
      }
      break;
    case "chip-breaking":
      expandCyclePoint(x, y, z);
      break;
    case "deep-drilling":
      if (P > 0) {
        expandCyclePoint(x, y, z);
      } else {
        writeBlock(
          gRetractModal.format(98), gAbsIncModal.format(90), gCycleModal.format(83),
          getCommonCycle(x, y, z, cycle.retract),
          "Q" + xyzFormat.format(cycle.incrementalDepth),
          feedOutput.format(F)
        );
      }
      break;
    case "fine-boring": // not supported
      expandCyclePoint(x, y, z);
      break;
    case "reaming":
      writeBlock(
        gRetractModal.format(98), gAbsIncModal.format(90), gCycleModal.format(85),
        getCommonCycle(x, y, z, cycle.retract),
        feedOutput.format(F)
      );
      break;

    case "boring":
      if (P > 0) {
        expandCyclePoint(x, y, z);
      } else {
        writeBlock(
          gRetractModal.format(98), gAbsIncModal.format(90), gCycleModal.format(85),
          getCommonCycle(x, y, z, cycle.retract),
          feedOutput.format(F)
        );
      }
      break;
    default:
      expandCyclePoint(x, y, z);
    }
  } else {
    if (cycleExpanded) {
      expandCyclePoint(x, y, z);
    } else {
      var _x = xOutput.format(x);
      var _y = yOutput.format(y);
      if (!_x && !_y) {
        xOutput.reset(); // at least one axis is required
        _x = xOutput.format(x);
      }
      writeBlock(_x, _y);
    }
  }
}

function onCycleEnd() {
  if (!cycleExpanded) {
    writeBlock(gCycleModal.format(80));
    zOutput.reset();
  }
}

var pendingRadiusCompensation = -1;

function onRadiusCompensation() {
  pendingRadiusCompensation = radiusCompensation;
}

var shapeArea = 0;
var shapePerimeter = 0;
var shapeSide = "inner";
var cuttingSequence = "";

function onParameter(name, value) {
  if ((name == "action") && (value == "pierce")) {
    // add delay if desired
  } else if (name == "shapeArea") {
    shapeArea = value;
  } else if (name == "shapePerimeter") {
    shapePerimeter = value;
  } else if (name == "shapeSide") {
    shapeSide = value;
  } else if (name == "beginSequence") {
    if (value == "piercing") {
      if (cuttingSequence != "piercing") {
        if (getProperty("allowHeadSwitches")) {
          // Allow head to be switched here
          // writeBlock(mFormat.format(0), '"Switch head for piercing."');
        }
      }
    } else if (value == "cutting") {
      if (cuttingSequence == "piercing") {
        if (getProperty("allowHeadSwitches")) {
          // Allow head to be switched here
          // writeBlock(mFormat.format(0), '"Switch head for cutting."');
        }
      }
    }
    cuttingSequence = value;
  }
}

function onPower(power) {
  writeBlock(mFormat.format(power ? 64 : 65)); // plasma on/off
}

function onRapid(_x, _y, _z) {
  // manual states linear interpolation - so not dog-leg motion expected
  // at least one axis is required
  if (pendingRadiusCompensation >= 0) {
    // ensure that we end at desired position when compensation is turned off
    xOutput.reset();
    yOutput.reset();
  }
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  if (x || y || z) {
    if (pendingRadiusCompensation >= 0) {
      pendingRadiusCompensation = -1;
      var toolNumber = tool.number;
      if (currentSection.type == TYPE_JET) {
        toolNumber = 1; // plasma
        if (currentSection.jetMode == JET_MODE_ETCHING) {
          toolNumber = 2; // marker
        }
      }
      switch (radiusCompensation) {
      case RADIUS_COMPENSATION_LEFT:
        writeBlock(gFormat.format(41), dFormat.format(toolNumber));
        break;
      case RADIUS_COMPENSATION_RIGHT:
        writeBlock(gFormat.format(42), dFormat.format(toolNumber));
        break;
      default:
        writeBlock(gFormat.format(40));
      }
    }
    writeBlock(gMotionModal.format(0), x, y, z);
    feedOutput.reset();
  }
}

function onLinear(_x, _y, _z, feed) {
  // at least one axis is required
  if (pendingRadiusCompensation >= 0) {
    // ensure that we end at desired position when compensation is turned off
    xOutput.reset();
    yOutput.reset();
  }
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  var f = feedOutput.format(feed);
  if (x || y || z) {
    if (pendingRadiusCompensation >= 0) {
      pendingRadiusCompensation = -1;
      var toolNumber = tool.number;
      if (currentSection.type == TYPE_JET) {
        toolNumber = 1; // plasma
        if (currentSection.jetMode == JET_MODE_ETCHING) {
          toolNumber = 2; // marker
        }
      }
      switch (radiusCompensation) {
      case RADIUS_COMPENSATION_LEFT:
        writeBlock(gFormat.format(41), dFormat.format(toolNumber));
        break;
      case RADIUS_COMPENSATION_RIGHT:
        writeBlock(gFormat.format(42), dFormat.format(toolNumber));
        break;
      default:
      }
    }
    writeBlock(gMotionModal.format(1), x, y, z, f);
  } else if (f) {
    if (getNextRecord().isMotion()) { // try not to output feed without motion
      feedOutput.reset(); // force feed on next line
    } else {
      writeBlock(gMotionModal.format(1), f);
    }
  }
}

function onRapid5D(_x, _y, _z, _a, _b, _c) {
  error(localize("The CNC does not support 5-axis simultaneous toolpath."));
}

function onLinear5D(_x, _y, _z, _a, _b, _c, feed) {
  error(localize("The CNC does not support 5-axis simultaneous toolpath."));
}

function onCircular(clockwise, cx, cy, cz, x, y, z, feed) {
  // one of X/Y and I/J are required and likewise

  if (pendingRadiusCompensation >= 0) {
    error(localize("Radius compensation cannot be activated/deactivated for a circular move."));
    return;
  }

  var start = getCurrentPosition();

  if (isFullCircle()) {
    if (getProperty("useRadius") || isHelical()) { // radius mode does not support full arcs
      linearize(tolerance);
      return;
    }
    switch (getCircularPlane()) {
    case PLANE_XY:
      writeBlock(conditional(getProperty("useZ"), gPlaneModal.format(17)), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), iOutput.format(cx - start.x, 0), jOutput.format(cy - start.y, 0), feedOutput.format(feed));
      break;
    case PLANE_ZX:
      if (getProperty("useZ")) {
        writeBlock(conditional(getProperty("useZ"), gPlaneModal.format(18)), gMotionModal.format(clockwise ? 2 : 3), zOutput.format(z), iOutput.format(cx - start.x, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
      } else {
        linearize(tolerance);
      }
      break;
    case PLANE_YZ:
      if (getProperty("useZ")) {
        writeBlock(conditional(getProperty("useZ"), gPlaneModal.format(19)), gMotionModal.format(clockwise ? 2 : 3), yOutput.format(y), jOutput.format(cy - start.y, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
      } else {
        linearize(tolerance);
      }
      break;
    default:
      linearize(tolerance);
    }
  } else if (!getProperty("useRadius")) {
    switch (getCircularPlane()) {
    case PLANE_XY:
      writeBlock(conditional(getProperty("useZ"), gPlaneModal.format(17)), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), iOutput.format(cx - start.x, 0), jOutput.format(cy - start.y, 0), feedOutput.format(feed));
      break;
    case PLANE_ZX:
      if (getProperty("useZ")) {
        writeBlock(conditional(getProperty("useZ"), gPlaneModal.format(18)), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), iOutput.format(cx - start.x, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
      } else {
        linearize(tolerance);
      }
      break;
    case PLANE_YZ:
      if (getProperty("useZ")) {
        writeBlock(conditional(getProperty("useZ"), gPlaneModal.format(19)), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), jOutput.format(cy - start.y, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
      } else {
        linearize(tolerance);
      }
      break;
    default:
      linearize(tolerance);
    }
  } else { // use radius mode
    var r = getCircularRadius();
    if (toDeg(getCircularSweep()) > 180) {
      r = -r; // allow up to <360 deg arcs
    }
    switch (getCircularPlane()) {
    case PLANE_XY:
      writeBlock(conditional(getProperty("useZ"), gPlaneModal.format(17)), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), "R" + rFormat.format(r), feedOutput.format(feed));
      break;
    case PLANE_ZX:
      if (getProperty("useZ")) {
        writeBlock(conditional(getProperty("useZ"), gPlaneModal.format(18)), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), "R" + rFormat.format(r), feedOutput.format(feed));
      } else {
        linearize(tolerance);
      }
      break;
    case PLANE_YZ:
      if (getProperty("useZ")) {
        writeBlock(conditional(getProperty("useZ"), gPlaneModal.format(19)), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), "R" + rFormat.format(r), feedOutput.format(feed));
      } else {
        linearize(tolerance);
      }
      break;
    default:
      linearize(tolerance);
    }
  }
}

var mapCommand = {
  COMMAND_STOP                    : 0,
  COMMAND_OPTIONAL_STOP           : 1,
  COMMAND_SPINDLE_CLOCKWISE       : 3,
  COMMAND_SPINDLE_COUNTERCLOCKWISE: 4,
  COMMAND_STOP_SPINDLE            : 5,
  COMMAND_COOLANT_ON              : 8,
  COMMAND_COOLANT_OFF             : 9
};

function onCommand(command) {
  switch (command) {
  case COMMAND_START_SPINDLE:
    onCommand(tool.clockwise ? COMMAND_SPINDLE_CLOCKWISE : COMMAND_SPINDLE_COUNTERCLOCKWISE);
    return;
  case COMMAND_POWER_ON:
    return;
  case COMMAND_POWER_OFF:
    return;
  case COMMAND_LOCK_MULTI_AXIS:
    return;
  case COMMAND_UNLOCK_MULTI_AXIS:
    return;
  case COMMAND_BREAK_CONTROL:
    return;
  case COMMAND_TOOL_MEASURE:
    return;
  }

  var stringId = getCommandStringId(command);
  var mcode = mapCommand[stringId];
  if (mcode != undefined) {
    writeBlock(mFormat.format(mcode));
  } else {
    onUnsupportedCommand(command);
  }
}

function onSectionEnd() {
  writeBlock(conditional(getProperty("useZ"), gPlaneModal.format(17)));
  forceAny();
}

function onClose() {
  if (getProperty("useZ") || getProperty("useM30")) {
    writeln("");
  }

  if (getProperty("useZ")) {
    writeBlock(gFormat.format(28), gAbsIncModal.format(91), "Z" + xyzFormat.format(0)); // retract
    writeBlock(gAbsIncModal.format(90));
    zOutput.reset();
  }

  if (getProperty("useZ")) {
    writeBlock(gFormat.format(28)); // move to reference point #1 - tool change position by default
  }

  if (getProperty("useM30")) {
    writeBlock(mFormat.format(30));
  }
  writeBlock(mFormat.format(2));
}

function setProperty(property, value) {
  properties[property].current = value;
}
